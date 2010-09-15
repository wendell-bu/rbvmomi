module RbVmomi::VIM

class ManagedObject
  def wait version, *pathSet
    version ||= ''
    all = pathSet.empty?
    filter = @soap.propertyCollector.CreateFilter :spec => {
      :propSet => [{ :type => self.class.wsdl_name, :all => all, :pathSet => pathSet }],
      :objectSet => [{ :obj => self }],
    }, :partialUpdates => false
    result = @soap.propertyCollector.WaitForUpdates(version: version)
    filter.DestroyPropertyFilter
    changes = result.filterSet[0].objectSet[0].changeSet
    changes.map { |h| [h.name.split('.').map(&:to_sym), h.val] }.each do |path,v|
      k = path.pop
      o = path.inject(self) { |b,k| b[k] }
      o._set_property k, v unless o == self
    end
    result.version
  end

  def wait_until *pathSet, &b
    ver = nil
    loop do
      ver = wait ver, *pathSet
      if x = b.call
        return x
      end
    end
  end

  def collect! *props
    spec = {
      objectSet: [{ obj: self }],
      propSet: [{
        pathSet: props,
        type: self.class.wsdl_name
      }]
    }
    @soap.propertyCollector.RetrieveProperties(specSet: [spec])[0].to_hash
  end

  def collect *props
    h = collect! *props
    a = props.map { |k| h[k.to_s] }
    if block_given?
      yield a
    else
      a
    end
  end
end

ManagedEntity
class ManagedEntity
  def path
    filterSpec = VIM.PropertyFilterSpec(
      objectSet: [{
        obj: self,
        selectSet: [
          VIM.TraversalSpec(
            name: 'tsME',
            type: 'ManagedEntity',
            path: 'parent',
            skip: false,
            selectSet: [
              VIM.SelectionSpec(name: 'tsME')
            ]
          )
        ]
      }],
      propSet: [{
        pathSet: %w(name parent),
        type: 'ManagedEntity'
      }]
    )

    result = @soap.propertyCollector.RetrieveProperties(specSet: [filterSpec])

    tree = {}
    result.each { |x| tree[x.obj] = [x['parent'], x['name']] }
    a = []
    cur = self
    while cur
      parent, name = *tree[cur]
      a << [cur, name]
      cur = parent
    end
    a.reverse
  end
end

Task
class Task
  def wait_for_completion
    wait_until('info.state') { %w(success error).member? info.state }
    case info.state
    when 'success'
      info.result
    when 'error'
      raise info.error
    end
  end

  def wait_for_progress
    wait_until('info.state', 'info.progress') do
      yield info.progress if block_given?
      %w(success error).member? info.state
    end
    case info.state
    when 'success'
      info.result
    when 'error'
      raise info.error
    end
  end
end

Folder
class Folder
  def find name, type=Object
    x = @soap.searchIndex.FindChild(entity: self, name: name)
    x if x.is_a? type
  end

  def traverse! path, type=Object
    traverse path, type, true
  end

  def traverse path, type=Object, create=false
    es = path.split('/').reject(&:empty?)
    return self if es.empty?
    final = es.pop

    p = es.inject(self) do |f,e|
      f.find(e, Folder) || (create && f.CreateFolder(name: e)) || return
    end

    if x = p.find(final, type)
      x
    elsif create and type == Folder
      p.CreateFolder(name: final)
    else
      nil
    end
  end

  def children
    childEntity
  end

  def ls
    Hash[children.map { |x| [x.name, x] }]
  end

  def inventory propSpecs={}
    propSet = [{ type: 'Folder', pathSet: ['name', 'parent'] }]
    propSpecs.each do |k,v|
      case k
      when VIM::ManagedEntity
        k = k.wsdl_name
      when Symbol, String
        k = k.to_s
      else
        fail "key must be a ManagedEntity"
      end

      h = { type: k }
      if v == :all
        h[:all] = true
      elsif v.is_a? Array
        h[:pathSet] = v + %w(parent)
      else
        fail "value must be an array of property paths or :all"
      end
      propSet << h
    end

    filterSpec = VIM.PropertyFilterSpec(
      objectSet: [
        obj: self,
        selectSet: [
          VIM.TraversalSpec(
            name: 'tsFolder',
            type: 'Folder',
            path: 'childEntity',
            skip: false,
            selectSet: [
              VIM.SelectionSpec(name: 'tsFolder')
            ]
          )
        ]
      ],
      propSet: propSet
    )

    result = @soap.propertyCollector.RetrieveProperties(specSet: [filterSpec])

    tree = { self => {} }
    result.each do |x|
      obj = x.obj
      next if obj == self
      h = Hash[x.propSet.map { |y| [y.name, y.val] }]
      tree[h['parent']][h['name']] = [obj, h]
      tree[obj] = {} if obj.is_a? VIM::Folder
    end
    tree
  end
end

Datastore
class Datastore
  def datacenter
    return @datacenter if @datacenter
    x = parent
    while not x.is_a? Datacenter
      x = x.parent
    end
    fail unless x.is_a? Datacenter
    @datacenter = x
  end

  def mkuripath path
    "/folder/#{URI.escape path}?dcPath=#{URI.escape datacenter.name}&dsName=#{URI.escape name}"
  end

  def exists? path
    req = Net::HTTP::Head.new mkuripath(path)
    req.initialize_http_header 'cookie' => @soap.cookie
    resp = @soap.http.request req
    case resp
    when Net::HTTPSuccess
      true
    when Net::HTTPNotFound
      false
    else
      fail resp.inspect
    end
  end

  def get path, io
    req = Net::HTTP::Get.new mkuripath(path)
    req.initialize_http_header 'cookie' => @soap.cookie
    resp = @soap.http.request(req)
    case resp
    when Net::HTTPSuccess
      io.write resp.body if resp.is_a? Net::HTTPSuccess
      true
    else
      fail resp.inspect
    end
  end

  def upload remote_path, local_path
    url = "http#{@soap.http.use_ssl? ? 's' : ''}://#{@soap.http.address}:#{@soap.http.port}#{mkuripath(remote_path)}"
    pid = spawn (ENV['CURL'] || "curl"), "-k", '--noproxy', '*',
                "-T", local_path,
                "-b", @soap.cookie,
                url,
                out: '/dev/null'
    Process.waitpid(pid, 0)
    fail "upload failed" unless $?.success?
  end
end

ServiceInstance
class ServiceInstance
  def find_datacenter path=nil
    if path
      content.rootFolder.traverse path, VIM::Datacenter
    else
      content.rootFolder.childEntity.grep(VIM::Datacenter).first
    end
  end

  def wait_for_multiple_tasks interested, tasks
    version = ''
    interested = (interested + ['info.state']).uniq
    task_props = Hash.new { |h,k| h[k] = {} }

    filter = @soap.propertyCollector.CreateFilter :spec => {
      :propSet => [{ :type => 'Task', :all => false, :pathSet => interested }],
      :objectSet => tasks.map { |x| { :obj => x } },
    }, :partialUpdates => false

    begin
      until task_props.size == tasks.size and task_props.all? { |k,h| %w(success error).member? h['info.state'] }
        result = @soap.propertyCollector.WaitForUpdates(version: version)
        version = result.version
        os = result.filterSet[0].objectSet

        os.each do |o|
          changes = Hash[o.changeSet.map { |x| [x.name, x.val] }]

          interested.each do |k|
            task = tasks.find { |x| x._ref == o.obj._ref }
            task_props[task][k] = changes[k] if changes.member? k
          end
        end

        yield task_props
      end
    ensure
      @soap.propertyCollector.CancelWaitForUpdates
      filter.DestroyPropertyFilter
    end
  end
end

Datacenter
class Datacenter
  def find_compute_resource path=nil
    if path
      hostFolder.traverse path, VIM::ComputeResource
    else
      hostFolder.childEntity.grep(VIM::ComputeResource).first
    end
  end

  def find_datastore name
    datastore.find { |x| x.name == name }
  end

  def find_vm folder_path, name
    vmFolder.traverse "#{folder_path}/#{name}", VIM::VirtualMachine
  end
end

VirtualMachine
class VirtualMachine
  def macs
    Hash[self.config.hardware.device.grep(VIM::VirtualEthernetCard).map { |x| [x.deviceInfo.label, x.macAddress] }]
  end
end

ObjectContent
class ObjectContent
  def [](k)
    to_hash[k]
  end

  def to_hash_uncached
    h = {}
    propSet.each do |x|
      fail if h.member? x.name
      h[x.name] = x.val
    end
    h
  end

  def to_hash
    @cached_hash ||= to_hash_uncached
  end
end

end

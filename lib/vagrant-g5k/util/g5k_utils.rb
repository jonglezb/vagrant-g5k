require 'net/ssh/multi'
require 'net/scp'
require 'json'
require 'digest'

require 'vagrant/util/retryable'

LAUNCHER_SCRIPT = "launch_vm_fwd.sh"

STRATEGY_SNAPSHOT = "snapshot"
STRATEGY_COPY = "copy"
STRATEGY_COW = "cow"
STRATEGY_DIRECT = "direct"

module VagrantPlugins
  module G5K
    class Connection
      include Vagrant::Util::Retryable

      attr_accessor :session

      attr_accessor :username

      attr_accessor :gateway

      attr_accessor :project_id

      attr_accessor :private_key

      attr_accessor :site

      attr_accessor :walltime

      attr_accessor :logger

      attr_accessor :node
      
      attr_accessor :pool

      attr_accessor :ports

      @@instance = nil

      def self.instance
        @@instance
      end


      def initialize(env)
        # provider specific config
        @provider_config = env[:machine].provider_config 
        @username = @provider_config.username
        @project_id = @provider_config.project_id
        @private_key = @provider_config.private_key
        @site = @provider_config.site
        @walltime = @provider_config.walltime
        @ports = @provider_config.ports
        @image= @provider_config.image
        @gateway = @provider_config.gateway
        # grab the network config of the vm
        @networks = env[:machine].config.vm.networks
        # to log to the ui
        @ui = env[:ui]

        @logger = Log4r::Logger.new("vagrant::environment")
        options = {
          :forward_agent => true
        }
        options[:keys] = [@private_key] if !@private_key.nil?
        if @gateway.nil?
          @logger.debug("connecting with #{@username} on site #{@site}")
          @session = Net::SSH.start(@site, @username, options)
        else
          @logger.debug("connecting with #{@username} on site #{@site} through #{@gateway}")
          gateway = Net::SSH::Gateway.new(@gateway, @username, options)
          @session = gateway.ssh(@site, @username, options)
        end
        @@instance = self
      end

      def create_local_working_dir(env)
        @session.exec("mkdir -p #{cwd(env)}")
      end

      def cwd(env)
        # remote working directory
        File.join(".vagrant", @project_id)
      end


      def check_job(job_id)
        oarstat = exec("oarstat --json")
        oarstat = JSON.load(oarstat)
        @logger.debug("Looking for the job id #{job_id} and username #{@username}")
        r = oarstat.select!{ |k,v| k == job_id and v["owner"] == @username }.values.first
        @logger.debug(r.inspect)
        # update the assigned hostname
        # this will be used to reach the vm 
        if !r.nil?
          @node = r["assigned_network_address"].first
        end
        return r
      end

      def delete_job(job_id)
        @ui.info("Deleting the associated job")
        exec("oardel -c -s 12 #{job_id}")
      end


      def check_local_storage(env)
        # Is the disk image already here ?
        if @image["pool"].nil?
          file = _check_file_local_storage(env)
        else
          file = _check_rbd_local_storage(env)
        end
        return file if file != ""
        return nil
      end

      def _check_file_local_storage(env)
        strategy = @image["backing"]
        file_to_check = ""
        if [STRATEGY_SNAPSHOT, STRATEGY_DIRECT].include?(strategy)
          file_to_check = @image["path"]
        else
          file_to_check = File.join(cwd(env), env[:machine].name.to_s)
        end
          exec("[ -f \"#{file_to_check}\" ] && echo #{file_to_check} || echo \"\"")
      end
  
      def _check_rbd_local_storage(env)
        strategy = @image["backing"]
        file_to_check = ""
        if [STRATEGY_SNAPSHOT, STRATEGY_DIRECT].include?(strategy)
          file_to_check = @image["rbd"]
        else
          file_to_check = File.join(cwd(env), env[:machine].name.to_s)
        end
        exec("(rbd --pool #{@image["pool"]} --id #{@image["id"]} --conf #{@image["conf"]} ls | grep \"^#{file_to_check}\") || echo \"\"")
      end


      def launch_vm(env)
        launcher_path = File.join(File.dirname(__FILE__), LAUNCHER_SCRIPT)
        @ui.info("Launching the VM on #{@site}")
        # Checking the subnet job
        # uploading the launcher
        launcher_remote_path = File.join(cwd(env), LAUNCHER_SCRIPT)
        upload(launcher_path, launcher_remote_path)

        # Generate partial arguments for the kvm command
        drive = _generate_drive(env)
        net = _generate_net()

        args = [drive, net].join(" ")
        # Submitting a new job
        # Getting the job_id as a ruby string
        job_id = exec("oarsub --json -t allow_classic_ssh -l \"nodes=1,walltime=#{@walltime}\" --name #{env[:machine].name} --checkpoint 60 --signal 12  \"#{launcher_remote_path} #{args}\" | grep \"job_id\"| cut -d':' -f2").gsub(/"/,"").strip

        begin
          retryable(:on => VagrantPlugins::G5K::Errors::JobNotRunning, :tries => 100, :sleep => 2) do
            @ui.info("Waiting for the job to be running")
            job = check_job(job_id)
            if job.nil? or job["state"] != "Running"
              raise VagrantPlugins::G5K::Errors::JobNotRunning 
            end
            # saving the id
            env[:machine].id = job["Job_Id"]
            break
          end
        rescue VagrantPlugins::G5K::Errors::JobNotRunning
          @ui.error("Tired of waiting")
          raise VagrantPlugins::G5K::Errors::JobNotRunning
        end
        @ui.info("VM booted on #{@site}")

      end

      def delete_disk(env)
        if [STRATEGY_DIRECT, STRATEGY_SNAPSHOT].include?(@image["backing"])
          @ui.error("Destroy not support for the strategy #{@image["backing"]}")
          return
        end

        if @image["pool"].nil?
          disk = File.join(cwd(env), env[:machine].name.to_s)
          exec("rm -f #{disk}")
        else
          disk = File.join(@image["pool"], cwd(env), env[:machine].name.to_s)
          begin
            retryable(:on => VagrantPlugins::G5K::Errors::CommandError, :tries => 10, :sleep => 5) do
              exec("rbd rm  #{disk} --conf #{@image["conf"]} --id #{@image["id"]}" )
              break
            end
          rescue VagrantPlugins::G5K::Errors::CommandError
            @ui.error("Reach max attempt while trying to remove the rbd")
            raise VagrantPlugins::G5K::Errors::CommandError
          end
        end
      end

      def close()
        # Terminate the session
        @session.close
      end



      def exec(cmd)
        @logger.debug("Executing #{cmd}")
        stdout = ""
        stderr = ""
        exit_code = 0
        @session.open_channel do |channel|
          channel.exec(cmd) do |ch, success|
            abort "could not execute command" unless success

            channel.on_data do |c, data|
              stdout << data.chomp
            end

            channel.on_extended_data do |c, type, data|
              stderr << data.chomp
            end

            channel.on_request("exit-status") do |c,data|
              exit_code = data.read_long
            end

            channel.on_close do |c|
            end
          end
        end
        @session.loop
        if exit_code != 0
          @logger.error(:stderr => stderr, :code => exit_code)
          raise VagrantPlugins::G5K::Errors::CommandError
        end
        @logger.debug("Returning #{stdout}")
        stdout
      end

      def upload(src, dst)
        @session.scp.upload!(src, dst)
      end

      def _generate_drive(env)
        # Depending on the strategy we generate the file location
        # This code smells a bit better 
        file = ""
        snapshot = ""
        if @image["backing"] == STRATEGY_SNAPSHOT
          snapshot = "-snapshot"
        end

        if @image["pool"].nil?
          file = _generate_drive_local(env)
        else
          file = _generate_drive_rbd(env)
        end
      
        return "-drive file=#{file},if=virtio #{snapshot}"
      end

      def _generate_drive_rbd(env)
        strategy = @image["backing"]
        if [STRATEGY_SNAPSHOT, STRATEGY_DIRECT].include?(strategy)
          file = File.join(@image["pool"], @image["rbd"])
        elsif strategy == STRATEGY_COW
          file = _rbd_clone_or_copy_image(env, clone = true)
        elsif strategy == STRATEGY_COPY
          file = _rbd_clone_or_copy_image(env, clone = false)
        end
        # encapsulate the file to a qemu ready disk description
        file = "rbd:#{file}:id=#{@image["id"]}:conf=#{@image["conf"]}"
        @logger.debug("Generated drive string : #{file}")
        return file
      end

      def _generate_drive_local(env)
        strategy = @image["backing"]
        if [STRATEGY_SNAPSHOT, STRATEGY_DIRECT].include?(strategy)
          file = @image["path"]
        elsif strategy == STRATEGY_COW
          file = _file_clone_or_copy_image(env, clone = true)
        elsif strategy == STRATEGY_COPY
          file = _file_clone_or_copy_image(env, clone = false)
        end
        return file
      end

      def _rbd_clone_or_copy_image(env, clone = true)
        # destination in the same pool under the .vagrant ns
        destination = File.join(@image["pool"], cwd(env), env[:machine].name.to_s)
        # Even if nothing bad will happen when the destination already exist, we should test it before
        exists = _check_rbd_local_storage(env)
        if exists == ""
          # we create the destination
          if clone
            # parent = pool/rbd@snap
            @ui.info("Cloning the rbd image")
            parent = File.join(@image["pool"], "#{@image["rbd"]}@#{@image["snapshot"]}")
            exec("rbd clone #{parent} #{destination} --conf #{@image["conf"]} --id #{@image["id"]}" )
          else
            @ui.info("Copying the rbd image (This may take some time)")
            # parent = pool/rbd@snap
            parent = File.join(@image["pool"], "#{@image["rbd"]}")
            exec("rbd cp #{parent} #{destination} --conf #{@image["conf"]} --id #{@image["id"]}" )
          end
        end
        return destination
      end
      
      def _file_clone_or_copy_image(env, clone = true)
          @ui.info("Clone the file image")
          file = File.join(cwd(env), env[:machine].name.to_s)
          exists = _check_file_local_storage(env)
          if exists == ""
            if clone 
              exec("qemu-img create -f qcow2 -b #{@image["path"]} #{file}")
            else
              exec("cp #{@image["path"]} #{file}")
            end
          end
          return file
      end

      def _generate_net()
        fwd_ports = @ports.map do |p|
          "hostfwd=tcp::#{p}"
        end.join(',')
        net = "-net nic,model=virtio -net user,#{fwd_ports}"
        @logger.info("Mapping ports")
        return net
      end
    end
  end
end

    

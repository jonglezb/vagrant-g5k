# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Sample Vagrantfile
#

# Allow to mount the home directory of G5k inside the VM
$script = <<SCRIPT
mkdir /g5k
mount -t 9p -o trans=virtio hostshare /g5k -oversion=9p2000.L
SCRIPT

Vagrant.configure(2) do |config|

    config.vm.provider "g5k" do |g5k, override|
      # This is mandatory for the shared folders to work correctly
      override.nfs.functional = false
      # vagrant-g5k only supports rsync shared folders
      override.vm.synced_folder ".", "/vagrant", type: "rsync", disabled: false

      override.ssh.insert_key = false

      # Mount the home dir
      override.vm.provision "shell", inline: $script
      # project id must be unique accross all
      # your projects using vagrant-g5k to avoid conflict
      # on vm disks
      g5k.project_id = "test-vagrant-g5k"

      #g5k.site = "igrida"
      g5k.site = "rennes"
      g5k.username = "msimonin"
      g5k.gateway = "access.grid5000.fr"
      g5k.walltime = "01:00:00"
      #g5k.private_key = "your private key"

      # Image backed on the frontend filesystem
      g5k.image = {
        :path    => "/home/msimonin/public/debian-8.7-amd64-bento.qcow2",
        :backing => "snapshot"
      }

      ## Bridged network : this allow VMs to communicate
      #g5k.net = {
      #  :type => "bridge"
      #}

      ## Nat network : VMs will only have access to the external world
      ## Forwarding ports will allow you to access services hosted inside the
      ## VM.
      g5k.net = {
        :type => "nat",
        :ports => ["2222-:22"]
      }

      ## OAR selection of resource
      g5k.oar = "virtual != 'none'"
      #g5k.oar = "virtual != 'None' and network_address in ('paranoia-2.rennes.grid5000.fr')"
      #g5k.oar = "network_address in ('igrida12-12.irisa.fr')"

      ## VM size customization default values are
      ## cpu => -1 -> all the cpu of the reserved node
      ## mem => -1 -> all the mem of the reserved node
      ##
      g5k.resources = {
        :cpu => 1,
        :mem => 2048
      }
      ## Job container id
      ## see https://www.grid5000.fr/mediawiki/index.php/Advanced_OAR#Container_jobs
      # g5k.job_container_id = "907864"

    end #g5k

    # This defines a VM
    # If you want to use a local virtual machine (vbox, libvirt...)
    # add your vagrant options below as usual.
    config.vm.define "test" do |my|
      my.vm.box = "dummy"
    end

end

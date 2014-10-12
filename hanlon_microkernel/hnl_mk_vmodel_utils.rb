require 'resolv'
require 'hanlon_microkernel/logging'
require 'hanlon_microkernel/hnl_mk_configuration_manager'

module HanlonMicrokernel::HnlVModelUtils
  include HanlonMicrokernel::Logging

  @config_manager = HanlonMicrokernel::HnlMkConfigurationManager.instance

  def mount_nfs_server
    nfs_server_ip = @config_manager.mk_nfs_server_ip

    begin
      if !!(nfs_server_ip =~ Resolv::IPv4::Regex)
        %x( mkdir -p /nfs )
        result = %x( mount -t nfs -o nolock #{nfs_server_ip}:/nfs /nfs)
        logger.error("mount nfs error: #{result}") unless nfs_mounted?
    end
    rescue => e
      logger.error("mount nfs error: #{e.message}")
    end
  end

  def umount_nfs_server
    begin
      result = %x( umount /nfs )
      logger.error("umount nfs error: #{result}") if nfs_mounted?
    rescue => e
      logger.error("umount nfs error: #{e.message}")
    end
  end

  def nfs_mounted?
    nfs_server_ip = @config_manager.mk_nfs_server_ip
    result = %x( grep #{nfs_server_ip} /proc/mounts )
    result == '' ? false : true
  end
end

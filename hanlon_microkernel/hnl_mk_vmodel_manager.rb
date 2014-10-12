# Used to manage the VModel process
#
#

require 'rubygems'
require 'yaml'
require 'open4'
require 'net/http'
require 'fileutils'
require 'singleton'
require 'hanlon_microkernel/logging'
require 'hanlon_microkernel/hnl_mk_vmodel_utils'
require 'hanlon_microkernel/hnl_mk_hardware_facter'
require 'hanlon_microkernel/hnl_mk_configuration_manager'

module HanlonMicrokernel
  class HnlMkVModelManager
    include Singleton
    include HanlonMicrokernel::Logging
    include HanlonMicrokernel::HnlVModelUtils

    DEF_MK_VMODEL_URI = 'http://localhost:2156/vmodel'
    # file used to track status of VModel process
    VMODEL_STATE_FILENAME = "/tmp/vmodel_state.yaml"
    attr_accessor :mac_id
    attr_accessor :uuid
    attr_accessor :host
    attr_accessor :tags

    def initialize
      @hardware_facter = HnlMkHardwareFacter.instance
      @config_manager = HnlMkConfigurationManager.instance
      @vmodel_uri = "#{@config_manager.mk_uri}/#{@config_manager.mk_vmodel_path}"
    end

    def send_request_to_hanlon(method, action, filename = nil)
      response = nil

      if @uuid
        begin
          if action == 'file'
            uri = URI "#{@vmodel_uri}/#{method}/file?uuid=#{@uuid}&mac_id=#{@mac_id}&name=#{File.basename(filename, File.extname(filename))}"
          else
            uri = URI "#{@vmodel_uri}/#{method}/#{action}?uuid=#{@uuid}&mac_id=#{@mac_id}"
          end

          response = Net::HTTP.get(uri)
          logger.debug("Response received for #{uri.to_s}: [#{response}]")
          save_file(filename, response) if action == 'file'
        rescue => e
          logger.error("Send request to Hanlon server failed: [#{e.message}]")
        end
      else
        logger.error("uuid is empty")
      end

      response
    end

    def save_file(filename, data)
      logger.debug("Saving as file: [#{filename}]")
      File.open("/tmp/#{filename}", 'w') {|file| file.write(data)}
    end

    def start_phase(phase, params = {})
      files = Array(params[:files])
      logger.debug("No file defined for phase #{phase}") if files.empty?

      logger.info("Start #{phase} with [enabled: #{params[:enabled]}, files: [#{files.join(',')}]]")
      ret = running_phase(phase, params[:enabled], files)
    end

    def running_phase(phase, enabled, files)
      current_state = 'idle'

      if nfs_mounted?
        phase_state = get_vmodel_state(phase)
        unless phase_state == 'running'
          current_state = phase
          if enabled == 'false'
            logger.info "Skip #{phase}"
            send_request_to_hanlon(phase, 'skip')
            set_vmodel_state(phase, 'skip')
            current_state = 'idle'
          else
            send_request_to_hanlon(phase, 'start')
            files.each {|file| send_request_to_hanlon(phase, 'file', file)}
            set_vmodel_state(phase, 'running')

            if files.first
              # run script for setting VModel phase in background
              run_script_background(files.first, phase)
            else
              logger.error("No script for setting #{phase}")
            end
          end
        end
      else
        mount_nfs_server
      end
      current_state
    end

    def end_phase(phase)
      phase_state = get_vmodel_state(phase)
      if phase_state == 'running'
        set_vmodel_state(phase, 'done')
        return "#{phase.capitalize} completed"
      else
        return "#{phase.capitalize} is not running"
      end
    end

    def run_script_background(filename, phase)
      if File.exist?("/tmp/#{filename}")
        logger.info "run script #{filename} in background"

        background_job = fork do
          start = Time.now
          message = {}
          status = Open4::popen4("sh /tmp/#{filename}") do |pid, stdin, stdout, stderr|
            message[:stdout] = stdout.read.strip
            message[:stderr] = "#{stderr.read.strip}"
          end

          if status.exitstatus == 0
            begin
              uri = URI(DEF_MK_VMODEL_URI)
              response = Net::HTTP.post_form(uri, {'phase' => phase, 'action' => 'end'})
              logger.debug "Change status of phase: [#{phase}] to 'done' => #{response}"
            rescue EOFError
              logger.error "Response received for [#{uri.to_s}] => EOFError"
            end
          else
            message[:stderr] = "Error Code: #{status.exitstatus}\n#{message[:stderr]}"
          end
        end

        Process.detach(background_job)
      else
        logger.error "can not find file: [#{filename}] in /tmp"
      end
    end

    def get_vmodel_state(phase)
      if File.exists?(VMODEL_STATE_FILENAME)
        vmodel_state = YAML::load(File.open(VMODEL_STATE_FILENAME))
      else
        vmodel_state = {}
      end
      vmodel_state.fetch(phase, 'none')
    end

    def set_vmodel_state(phase, state)
      if File.exists?(VMODEL_STATE_FILENAME)
        vmodel_state = YAML::load(File.open(VMODEL_STATE_FILENAME))
        vmodel_state[phase] = state if vmodel_state.key?(phase)
        File.open(VMODEL_STATE_FILENAME, 'w') { |file| YAML.dump(vmodel_state, file) }
      else
        logger.error("Can not set #{phase} to #{state}")
      end
    end

    def reset_vmodel_state
      data = YAML::load(File.open(VMODEL_STATE_FILENAME))
      data.each_key {|key| data[key] = nil}
      File.open(VMODEL_STATE_FILENAME, 'w') {|file| YAML.dump(data, file)}
    end
  end
end

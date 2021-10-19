require "sam"
require "file_utils"
require "colorize"
require "totem"
require "./utils/utils.cr"


desc "Sets up Kubescape in the K8s Cluster"
task "install_kubescape" do |_, args|
  Log.info {"install_kubescape"}
  # version = `curl --silent "https://api.github.com/repos/armosec/kubescape/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'`
  unless args.named["offline"]?
      url = "https://github.com/armosec/kubescape/releases/download/v#{KUBESCAPE_VERSION}/kubescape-ubuntu-latest"
    current_dir = FileUtils.pwd 
    unless Dir.exists?("#{current_dir}/#{TOOLS_DIR}/kubescape")
      FileUtils.mkdir_p("#{current_dir}/#{TOOLS_DIR}/kubescape") 
      write_file = "#{current_dir}/#{TOOLS_DIR}/kubescape/kubescape"
      Log.info { "url: #{url}" }
      Log.info { "write_file: #{write_file}" }
      resp = Halite.follow.get("#{url}") do |response| 
        File.write("#{write_file}", response.body_io)
      end 
      Log.debug {"resp: #{resp}"}
      raise "Unable to download" if resp.status_code == 404 
      stderr = IO::Memory.new
      status = Process.run("chmod +x #{write_file}", shell: true, output: stderr, error: stderr)
      success = status.success?
      raise "Unable to make #{write_file} executable" if success == false
    end
  end
end

desc "Kubescape Scan"
task "kubescape_scan", ["install_kubescape"] do |_, args|
  Kubescape.scan
end

desc "Uninstall Kubescape"
task "uninstall_kubescape" do |_, args|
  current_dir = FileUtils.pwd 
  Log.for("verbose").info { "uninstall_kubescape" } if check_verbose(args)
  FileUtils.rm_rf("#{current_dir}/#{TOOLS_DIR}/kubescape")
end

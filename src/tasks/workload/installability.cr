# coding: utf-8
require "sam"
require "file_utils"
require "colorize"
require "totem"
require "../utils/utils.cr"

desc "The CNF test suite checks to see if CNFs support horizontal scaling (across multiple machines) and vertical scaling (between sizes of machines) by using the native K8s kubectl"
task "installability", ["install_script_helm", "helm_chart_valid", "helm_chart_published", "helm_deploy"] do |_, args|
  stdout_score("installability")
end

desc "Will the CNF install using helm with helm_deploy?"
task "helm_deploy" do |_, args|
  unless check_destructive(args)
    Log.info { "skipping helm_deploy: not in destructive mode" }
    puts "SKIPPED: Helm Deploy".colorize(:yellow)
    next
  end
  Log.info { "Running helm_deploy in destructive mode!" }
  Log.for("verbose").info { "helm_deploy" } if check_verbose(args)
  Log.info { "helm_deploy args: #{args.inspect}" }
  if check_cnf_config(args) || CNFManager.destination_cnfs_exist?
    CNFManager::Task.task_runner(args) do |args, config|
      
      emoji_helm_deploy="⎈🚀"
      helm_chart = config.cnf_config[:helm_chart]
      helm_directory = config.cnf_config[:helm_directory]
      release_name = config.cnf_config[:release_name]
      yml_file_path = config.cnf_config[:yml_file_path]
      configmap = KubectlClient::Get.configmap("cnf-testsuite-#{release_name}-startup-information")
      #TODO check if json is empty
      helm_used = configmap["data"].as_h["helm_used"].as_s

      if helm_used == "true" 
        upsert_passed_task("helm_deploy", "✔️  PASSED: Helm deploy successful #{emoji_helm_deploy}")
      else
        upsert_failed_task("helm_deploy", "✖️  FAILED: Helm deploy failed #{emoji_helm_deploy}")
      end
    end
  else
    upsert_failed_task("helm_deploy", "✖️  FAILED: No cnf_testsuite.yml found! Did you run the setup task?")
  end
end

desc "Does the install script use helm?"
task "install_script_helm" do |_, args|
  CNFManager::Task.task_runner(args) do |args, config|
    # config = CNFManager.parsed_config_file(CNFManager.ensure_cnf_testsuite_yml_path(args.named["cnf-config"].as(String)))
    
    emoji_helm_script="⎈📦"
    found = 0
    # destination_cnf_dir = CNFManager.cnf_destination_dir(CNFManager.ensure_cnf_testsuite_dir(args.named["cnf-config"].as(String)))
    # install_script = config.get("install_script").as_s?
    install_script = config.cnf_config[:install_script]
    Log.info { "install_script: #{install_script}" }
    destination_cnf_dir = config.cnf_config[:destination_cnf_dir]
    Log.info { "destination_cnf_dir: #{destination_cnf_dir}" }
    Log.for("verbose").debug { destination_cnf_dir } if check_verbose(args)
    if !install_script.empty?
      response = String::Builder.new
      content = File.open("#{destination_cnf_dir}/#{install_script}") do |file|
        file.gets_to_end
      end
      # LOGGING.debug content
      if /helm/ =~ content
        found = 1
      end
      if found < 1
        upsert_failed_task("install_script_helm", "✖️  FAILED: Helm not found in supplied install script #{emoji_helm_script}")
      else
        upsert_passed_task("install_script_helm", "✔️  PASSED: Helm found in supplied install script #{emoji_helm_script}")
      end
    else
      upsert_passed_task("install_script_helm", "✔️  PASSED (by default): No install script provided")
    end
  end
end

task "helm_chart_published", ["helm_local_install"] do |_, args|
  CNFManager::Task.task_runner(args) do |args, config|
    if check_verbose(args)
      Log.for("verbose").info { "helm_chart_published" }
      Log.for("verbose").debug { "helm_chart_published args.raw: #{args.raw}" }
      Log.for("verbose").debug { "helm_chart_published args.named: #{args.named}" }
    end

    # config = cnf_testsuite_yml
    # config = CNFManager.parsed_config_file(CNFManager.ensure_cnf_testsuite_yml_path(args.named["cnf-config"].as(String)))
    # helm_chart = "#{config.get("helm_chart").as_s?}"
    helm_chart = config.cnf_config[:helm_chart]
    emoji_published_helm_chart="⎈📦🌐"
    current_dir = FileUtils.pwd
    helm = BinarySingleton.helm
    Log.for("verbose").debug { helm } if check_verbose(args)

    if CNFManager.helm_repo_add(args: args)
      unless helm_chart.empty?
        helm_search_cmd = "#{helm} search repo #{helm_chart}"
        Log.info { "helm search command: #{helm_search_cmd}" }
        Process.run(
          helm_search_cmd,
          shell: true,
          output: helm_search_stdout = IO::Memory.new,
          error: helm_search_stderr = IO::Memory.new
        )
        helm_search = helm_search_stdout.to_s
        Log.for("verbose").debug { "#{helm_search}" } if check_verbose(args)
        unless helm_search =~ /No results found/
          upsert_passed_task("helm_chart_published", "✔️  PASSED: Published Helm Chart Found #{emoji_published_helm_chart}")
        else
          upsert_failed_task("helm_chart_published", "✖️  FAILED: Published Helm Chart Not Found #{emoji_published_helm_chart}")
        end
      else
        upsert_failed_task("helm_chart_published", "✖️  FAILED: Published Helm Chart Not Found #{emoji_published_helm_chart}")
      end
    else
      upsert_failed_task("helm_chart_published", "✖️  FAILED: Published Helm Chart Not Found #{emoji_published_helm_chart}")
    end
  end
end

task "helm_chart_valid", ["helm_local_install"] do |_, args|
  CNFManager::Task.task_runner(args) do |args|
    if check_verbose(args)
      Log.for("verbose").info { "helm_chart_valid" }
      Log.for("verbose").debug { "helm_chart_valid args.raw: #{args.raw}" }
      Log.for("verbose").debug { "helm_chart_valid args.named: #{args.named}" }
    end

    response = String::Builder.new

    config = CNFManager.parsed_config_file(CNFManager.ensure_cnf_testsuite_yml_path(args.named["cnf-config"].as(String)))
    # helm_directory = config.get("helm_directory").as_s
    helm_directory = optional_key_as_string(config, "helm_directory")
    if helm_directory.empty?
      working_chart_directory = "exported_chart"
    else
      working_chart_directory = helm_directory
    end

    if args.named.keys.includes? "cnf_chart_path"
      working_chart_directory = args.named["cnf_chart_path"]
    end

    Log.for("verbose").debug { "working_chart_directory: #{working_chart_directory}" } if check_verbose(args)

    current_dir = FileUtils.pwd
    Log.for("verbose").debug { current_dir } if check_verbose(args)
    helm = BinarySingleton.helm
    emoji_helm_lint="⎈📝☑️"

    destination_cnf_dir = CNFManager.cnf_destination_dir(CNFManager.ensure_cnf_testsuite_dir(args.named["cnf-config"].as(String)))

    helm_lint_cmd = "#{helm} lint #{destination_cnf_dir}/#{working_chart_directory}"
    helm_lint_status = Process.run(
      helm_lint_cmd,
      shell: true,
      output: helm_lint_stdout = IO::Memory.new,
      error: helm_link_stderr = IO::Memory.new
    )
    helm_lint = helm_lint_stdout.to_s
    Log.for("verbose").debug { "helm_lint: #{helm_lint}" } if check_verbose(args)

    if helm_lint_status.success?
      upsert_passed_task("helm_chart_valid", "✔️  PASSED: Helm Chart #{working_chart_directory} Lint Passed #{emoji_helm_lint}")
    else
      upsert_failed_task("helm_chart_valid", "✖️  FAILED: Helm Chart #{working_chart_directory} Lint Failed #{emoji_helm_lint}")
    end
  end
end

task "validate_config" do |_, args|
  yml = CNFManager.parsed_config_file(CNFManager.ensure_cnf_testsuite_yml_path(args.named["cnf-config"].as(String)))
  valid, warning_output = CNFManager.validate_cnf_testsuite_yml(yml)
  emoji_config="📋"
  if valid
    stdout_success "✔️ PASSED: CNF configuration validated #{emoji_config}"
  else
    stdout_failure "❌ FAILED: Critical Error with CNF Configuration. Please review USAGE.md for steps to set up a valid CNF configuration file #{emoji_config}"
  end
end

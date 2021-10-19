# coding: utf-8
require "sam"
require "file_utils"
require "colorize"
require "totem"
require "../utils/utils.cr"

desc "CNF containers should be isolated from one another and the host.  The CNF Test suite uses tools like Falco, Sysdig Inspect and gVisor"
task "security", ["privileged", "non_root_user", "symlink_file_system", "privilege_escalation", "insecure_capabilities", "dangerous_capabilities"] do |_, args|
  stdout_score("security")
end

desc "Check if any containers are running in as root"
task "non_root_user", ["install_falco"] do |_, args|
   unless KubectlClient::Get.resource_wait_for_install("Daemonset", "falco") 
     LOGGING.info "Falco Failed to Start"
     upsert_skipped_task("non_root_user", "✖️  SKIPPED: Skipping non_root_user: Falco failed to install. Check Kernel Headers are installed on the Host Systems(K8s).")
     node_pods = KubectlClient::Get.pods_by_nodes(KubectlClient::Get.schedulable_nodes_list)
     pods = KubectlClient::Get.pods_by_label(node_pods, "app", "falco")
     falco_pod_name = pods[0].dig("metadata", "name")
     LOGGING.info "Falco Pod Name: #{falco_pod_name}"
     resp = KubectlClient.logs(falco_pod_name)
     puts "Falco Logs: #{resp[:output]}"
     next
   end

   CNFManager::Task.task_runner(args) do |args,config|
     VERBOSE_LOGGING.info "non_root_user" if check_verbose(args)
     LOGGING.debug "cnf_config: #{config}"
     fail_msgs = [] of String
     task_response = CNFManager.workload_resource_test(args, config) do |resource, container, initialized|
       test_passed = true
       LOGGING.info "Falco is Running"
       kind = resource["kind"].as_s.downcase
       case kind 
       when  "deployment","statefulset","pod","replicaset", "daemonset"
         resource_yaml = KubectlClient::Get.resource(resource[:kind], resource[:name])
         pods = KubectlClient::Get.pods_by_resource(resource_yaml)
         # containers = KubectlClient::Get.resource_containers(kind, resource[:name]) 
         pods.map do |pod|
           # containers.as_a.map do |container|
           #   container_name = container.dig("name")
           pod_name = pod.dig("metadata", "name")
           # if Falco.find_root_pod(pod_name, container_name)
           if Falco.find_root_pod(pod_name)
             fail_msg = "resource: #{resource} and pod #{pod_name} uses a root user"
             unless fail_msgs.find{|x| x== fail_msg}
               puts fail_msg.colorize(:red)
               fail_msgs << fail_msg
             end
             test_passed=false
           end
         end
       end
       test_passed
     end
     emoji_no_root="🚫√"
     emoji_root="√"

     if task_response
       upsert_passed_task("non_root_user", "✔️  PASSED: Root user not found #{emoji_no_root}")
     else
       upsert_failed_task("non_root_user", "✖️  FAILED: Root user found #{emoji_root}")
     end
   end
end

desc "Check if any containers are running in privileged mode"
task "privileged" do |_, args|
  CNFManager::Task.task_runner(args) do |args, config|
    VERBOSE_LOGGING.info "privileged" if check_verbose(args)
    white_list_container_names = config.cnf_config[:white_list_container_names]
    VERBOSE_LOGGING.info "white_list_container_names #{white_list_container_names.inspect}" if check_verbose(args)
    violation_list = [] of String
    task_response = CNFManager.workload_resource_test(args, config) do |resource, container, initialized|

      privileged_list = KubectlClient::Get.privileged_containers
      white_list_containers = ((PRIVILEGED_WHITELIST_CONTAINERS + white_list_container_names) - [container])
      # Only check the containers that are in the deployed helm chart or manifest
      (privileged_list & ([container.as_h["name"].as_s] - white_list_containers)).each do |x|
        violation_list << x
      end
      if violation_list.size > 0
        false
      else
        true
      end
    end
    LOGGING.debug "violator list: #{violation_list.flatten}"
    emoji_security="🔓🔑"
    if task_response 
      upsert_passed_task("privileged", "✔️  PASSED: No privileged containers #{emoji_security}")
    else
      upsert_failed_task("privileged", "✖️  FAILED: Found #{violation_list.size} privileged containers: #{violation_list.inspect} #{emoji_security}")
    end
  end
end

desc "Check if any containers are running in privileged mode"
task "privilege_escalation", ["kubescape_scan"] do |_, args|
  unless args.named["offline"]?
      CNFManager::Task.task_runner(args) do |args, config|
    VERBOSE_LOGGING.info "privilege_escalation" if check_verbose(args)
    results_json = Kubescape.parse
    test_json = Kubescape.test_by_test_name(results_json, "Allow privilege escalation")

    emoji_security="🔓🔑"
    if Kubescape.test_passed?(test_json) 
      upsert_passed_task("privilege_escalation", "✔️  PASSED: No containers that allow privilege escalation were found #{emoji_security}")
    else
      resp = upsert_failed_task("privilege_escalation", "✖️  FAILED: Found containers that allow privilege escalation #{emoji_security}")
      Kubescape.alerts_by_test(test_json).map{|t| puts "\n#{t}".colorize(:red)}
      puts "Remediation: #{Kubescape.remediation(test_json)}\n".colorize(:red)
      resp
    end
  end
  end
end

desc "Check if an attacker can use symlink for arbitrary host file system access."
task "symlink_file_system", ["kubescape_scan"] do |_, args|
  unless args.named["offline"]?
      CNFManager::Task.task_runner(args) do |args, config|
      VERBOSE_LOGGING.info "symlink_file_system" if check_verbose(args)
      results_json = Kubescape.parse
      test_json = Kubescape.test_by_test_name(results_json, "CVE-2021-25741 - Using symlink for arbitrary host file system access.")

      emoji_security="🔓🔑"
      if Kubescape.test_passed?(test_json) 
        upsert_passed_task("symlink_file_system", "✔️  PASSED: No containers allow a symlink attack #{emoji_security}")
      else
        resp = upsert_failed_task("symlink_file_system", "✖️  FAILED: Found containers that allow a symlink attack #{emoji_security}")
        Kubescape.alerts_by_test(test_json).map{|t| puts "\n#{t}".colorize(:red)}
        puts "Remediation: #{Kubescape.remediation(test_json)}\n".colorize(:red)
        resp
      end
    end
  end
end

desc "Check if applications credentials are in configuration files."
task "application_credentials", ["kubescape_scan"] do |_, args|
  unless args.named["offline"]?
      CNFManager::Task.task_runner(args) do |args, config|
      VERBOSE_LOGGING.info "application_credentials" if check_verbose(args)
      results_json = Kubescape.parse
      test_json = Kubescape.test_by_test_name(results_json, "Applications credentials in configuration files")

      emoji_security="🔓🔑"
      if Kubescape.test_passed?(test_json) 
        upsert_passed_task("application_credentials", "✔️  PASSED: No applications credentials in configuration files #{emoji_security}")
      else
        resp = upsert_failed_task("application_credentials", "✖️  FAILED: Found applications credentials in configuration files #{emoji_security}")
        Kubescape.alerts_by_test(test_json).map{|t| puts "\n#{t}".colorize(:red)}
        puts "Remediation: #{Kubescape.remediation(test_json)}\n".colorize(:red)
        resp
      end
    end
  end
end

desc "Check if potential attackers may gain access to a POD and inherit access to the entire host network. For example, in AWS case, they will have access to the entire VPC."
task "host_network", ["kubescape_scan"] do |_, args|
  unless args.named["offline"]?
      CNFManager::Task.task_runner(args) do |args, config|
      VERBOSE_LOGGING.info "host_network" if check_verbose(args)
      results_json = Kubescape.parse
      test_json = Kubescape.test_by_test_name(results_json, "hostNetwork access")

      emoji_security="🔓🔑"
      if Kubescape.test_passed?(test_json) 
        upsert_passed_task("host_network", "✔️  PASSED: No host network attached to pod #{emoji_security}")
      else
        resp = upsert_failed_task("host_network", "✖️  FAILED: Found host network attached to pod #{emoji_security}")
        Kubescape.alerts_by_test(test_json).map{|t| puts "\n#{t}".colorize(:red)}
        puts "Remediation: #{Kubescape.remediation(test_json)}\n".colorize(:red)
        resp
      end
    end
  end
end

desc "Potential attacker may gain access to a POD and steal its service account token. Therefore, it is recommended to disable automatic mapping of the service account tokens in service account configuration and enable it only for PODs that need to use them."
task "service_account_mapping", ["kubescape_scan"] do |_, args|
  unless args.named["offline"]?
      CNFManager::Task.task_runner(args) do |args, config|
    VERBOSE_LOGGING.info "service_account_mapping" if check_verbose(args)
    results_json = Kubescape.parse
    test_json = Kubescape.test_by_test_name(results_json, "Automatic mapping of service account")

    emoji_security="🔓🔑"
    if Kubescape.test_passed?(test_json) 
      upsert_passed_task("service_account_mapping", "✔️  PASSED: No service accounts automatically mapped #{emoji_security}")
    else
      resp = upsert_failed_task("service_account_mapping", "✖️  FAILED: Service accounts automatically mapped #{emoji_security}")
      Kubescape.alerts_by_test(test_json).map{|t| puts "\n#{t}".colorize(:red)}
      puts "Remediation: #{Kubescape.remediation(test_json)}\n".colorize(:red)
      resp
    end
  end
  end
end

desc "Check if the containers have insecure capabilities."
task "insecure_capabilities", ["kubescape_scan"] do |_, args|
  next if args.named["offline"]?

  CNFManager::Task.task_runner(args) do |args, config|
    Log.for("verbose").info { "insecure_capabilities" } if check_verbose(args)
    results_json = Kubescape.parse
    test_json = Kubescape.test_by_test_name(results_json, "Insecure capabilities")

    emoji_security = "🔓🔑"
    if Kubescape.test_passed?(test_json)
      upsert_passed_task("insecure_capabilities", "✔️  PASSED: Containers with insecure capabilities were not found #{emoji_security}")
    else
      resp = upsert_failed_task("insecure_capabilities", "✖️  FAILED: Found containers with insecure capabilities #{emoji_security}")
      Kubescape.alerts_by_test(test_json).map{|t| puts "\n#{t}".colorize(:red)}
      puts "Remediation: #{Kubescape.remediation(test_json)}\n".colorize(:red)
      resp
    end
  end
end

desc "Check if the containers have dangerous capabilities."
task "dangerous_capabilities", ["kubescape_scan"] do |_, args|
  next if args.named["offline"]?

  CNFManager::Task.task_runner(args) do |args, config|
    Log.for("verbose").info { "dangerous_capabilities" } if check_verbose(args)
    results_json = Kubescape.parse
    test_json = Kubescape.test_by_test_name(results_json, "Dangerous capabilities")

    emoji_security = "🔓🔑"
    if Kubescape.test_passed?(test_json)
      upsert_passed_task("dangerous_capabilities", "✔️  PASSED: Containers with dangerous capabilities were not found #{emoji_security}")
    else
      resp = upsert_failed_task("dangerous_capabilities", "✖️  FAILED: Found containers with dangerous capabilities #{emoji_security}")
      Kubescape.alerts_by_test(test_json).map{|t| puts "\n#{t}".colorize(:red)}
      puts "Remediation: #{Kubescape.remediation(test_json)}\n".colorize(:red)
      resp
    end
  end
end

## [COOL-465 postmortem](https://chefio.atlassian.net/browse/COOL-465)

## Fri Jul 22 2016

* 15:27:00 - @thommay opens [PR 5131](https://github.com/chef/chef/pull/5131)

## Sat Jul 23 2016

* 11:22:00 - @mwrockx opens [PR 5133](https://github.com/chef/chef/pull/5133)

## Mon Jul 25 2016

### GIT TIMEOUT ISSUE

* 11:19:57 - @mwrockx merges [PR 5133](https://github.com/chef/chef/pull/5133) to [master](https://github.com/chef/chef/commit/bdd11de5be6860f45417faf7abfbabc8be85cc5b).
* 11:19:57 - @julia [bumps version](http://lita-relay-public.chef.co/bumpbot/handlers/774/handler.log) of [master](https://github.com/chef/chef/commit/ff9d72e533a5a5e5afa53d4cf9a8feef3078925f) to 12.13.13.
* 11:20:08 - @julia starts [12.13.13 #73](http://manhattan.ci.chef.co/job/chef-trigger-release/73/).
* 11:52:48 - [12.13.13 #73 build 212](http://manhattan.ci.chef.co/job/chef-build/212/) fails due to [git timeout](http://manhattan.ci.chef.co/job/chef-build/architecture=x86_64,platform=el-5,project=chef,role=builder/212/consoleFull#855548591c9fbf01e-8a27-4a13-8096-84559a2e611e).

### GIT TIMEOUT ISSUE

* 14:38:20 - @mwrockx starts ad-hoc [12.13.13 #105](http://manhattan.ci.chef.co/job/chef-trigger-ad_hoc/105/).
* 15:11:20 - [12.13.13 #105 build 213](http://manhattan.ci.chef.co/job/chef-build/213/) fails due to [git timeout](http://manhattan.ci.chef.co/job/chef-build/architecture=x86_64,platform=el-6,project=chef,role=builder/213/consoleFull#855548591c9fbf01e-8a27-4a13-8096-84559a2e611e).

### GIT TIMEOUT ISSUE

* 15:30:18 - @mwrockx starts retry [12.13.13 #73 build 214](http://manhattan.ci.chef.co/job/chef-build/214/).
* 16:03:18 - [12.13.13 #73 build 214](http://manhattan.ci.chef.co/job/chef-build/214/) fails due to [git timeout](http://manhattan.ci.chef.co/job/chef-build/architecture=x86_64,platform=debian-6,project=chef,role=builder/214/consoleFull#855548591c9fbf01e-8a27-4a13-8096-84559a2e611e).

### 12.13.13 SUCCEEDS

* 16:26:24 - @mwrockx starts retry [12.13.13 #73 build 215](http://manhattan.ci.chef.co/job/chef-build/215/).
* 19:18:04 - [12.13.13 #73 succeeds](http://manhattan.ci.chef.co/job/chef-promote/36/).

## Tue Jul 26 2016

### GIT TIMEOUT ISSUE

* 06:07:59 - @mwrockx merges [PR 5131](https://github.com/chef/chef/pull/5131) to [master](https://github.com/chef/chef/commit/04f658432df6cdae57102129f55789c2bf23dae6).
* 06:07:59 - @julia [bumps version](http://lita-relay-public.chef.co/bumpbot/handlers/780/handler.log) of [master](https://github.com/chef/chef/commit/e2559fdd77256fa5ae350b52c77d893ff471d422) to 12.13.14.
* 06:08:21 - @julia starts [12.13.14 #74](http://manhattan.ci.chef.co/job/chef-trigger-release/74/).
* 06:41:56 - [12.13.14 #74 build 216](http://manhattan.ci.chef.co/job/chef-build/216/) fails due to [git timeout](http://manhattan.ci.chef.co/job/chef-build/architecture=x86_64,platform=el-7,project=chef,role=builder/216/consoleFull#855548591c9fbf01e-8a27-4a13-8096-84559a2e611e).

### GIT TIMEOUT ISSUE

* 08:40:33 - @mwrockx starts retry [12.13.14 #74 build 217](http://manhattan.ci.chef.co/job/chef-build/217/).
* 09:13:33 - [12.13.14 #74 build 217](http://manhattan.ci.chef.co/job/chef-build/217/) fails due to [git timeout](http://manhattan.ci.chef.co/job/chef-build/architecture=i386,platform=freebsd-10,project=chef,role=builder/217/consoleFull#855548591c9fbf01e-8a27-4a13-8096-84559a2e611e).

### CCR OF NEXUS TESTERS

* 11:16:00 - @ryanh notices nexus and ios_xr machines are down and reboots them
* 11:27:46 - @shain starts ad-hoc [12.13.14 #106](http://manhattan.ci.chef.co/job/chef-trigger-ad_hoc/106/).
* 11:37:00 - @shain CCRs chef-nexus-7-tester-fd11dc
* 11:48:00 - @shain CCRs angrychef-nexus-7-tester-439e8e
* 13:19:51 - [12.13.14 #106 succeeds](http://manhattan.ci.chef.co/job/chef-promote/37/).

### ACCEPTANCE: AWS INSTANCE READY TIMEOUT

* 11:51:50 - @mwrockx starts retry [12.13.14 #74 build 219](http://manhattan.ci.chef.co/job/chef-build/219/).
* 14:37:04 - [12.13.14 #74 test 98](http://manhattan.ci.chef.co/job/chef-test/98/) fails due to `aws instance ready timeout` in [top-cookbooks::provision](http://manhattan.ci.chef.co/job/chef-test/98/architecture=x86_64,platform=acceptance,project=chef,role=tester/artifact/chef-acceptance-data/logs/top-cookbooks/provision.log).

### AD HOC 12.13.14 SUCCEEDS

* 12:33:22 - @mwrockx starts ad-hoc [12.13.14 #107](http://manhattan.ci.chef.co/job/chef-trigger-ad_hoc/107/)
* 15:55:20 - [12.13.14 #107 succeeds.](http://manhattan.ci.chef.co/job/chef-promote/38/)

### ACCEPTANCE: `undefined method 'set' for Aws::Query::ParamList`

* 14:56:53 - @mwrockx starts retry [12.13.14 #74 test 100](http://manhattan.ci.chef.co/job/chef-test/100/).
* 15:40:53 - [12.13.14 #74 test 100](http://manhattan.ci.chef.co/job/chef-test/100/) fails due to `undefined method 'set' for #<Aws::Query::ParamList:0x00000004364d78>` in [fips-integration-centos-6](http://manhattan.ci.chef.co/job/chef-test/100/architecture=x86_64,platform=acceptance,project=chef,role=tester/artifact/chef-acceptance-data/logs/fips/converge/fips-integration-centos-6.log).

### CCR ios-xr

* 18:48:00: @shain CCRs chef-ios_xr-6-builder-ff30c9

### ACCEPTANCE: `wrong number of arguments (4 for 0) to aws-sdk-core/xml/parser/stack.rb:49:in 'initialize'`

* 19:13:14 - @mwrockx starts retry [12.13.14 #74 test 101](http://manhattan.ci.chef.co/job/chef-test/101/).
* 20:31:14 - [12.13.14 #74 test 101](http://manhattan.ci.chef.co/job/chef-test/101/) fails due to `wrong number of arguments (4 for 0) to aws-sdk-core/xml/parser/stack.rb:49:in 'initialize'` in [fips-integration-windows-2012r2](http://manhattan.ci.chef.co/job/chef-test/101/architecture=x86_64,platform=acceptance,project=chef,role=tester/artifact/chef-acceptance-data/logs/fips/converge/fips-integration-windows-2012r2.log) and [fips-unit-functional-windows-2012r2](http://manhattan.ci.chef.co/job/chef-test/101/architecture=x86_64,platform=acceptance,project=chef,role=tester/artifact/chef-acceptance-data/logs/fips/converge/fips-unit-functional-windows-2012r2.log).

### ACCEPTANCE: `wrong number of arguments (1 for 0) to aws-sdk-core.rb:283:in 'initialize'` and `aws ssh connection timeout`

* 20:03:51 - @mwrockx starts retry [12.13.14 #74 test 102](http://manhattan.ci.chef.co/job/chef-test/102/).
* 21:32:51 - [12.13.14 #74 test 102](http://manhattan.ci.chef.co/job/chef-test/102/) fails due to `wrong number of arguments (1 for 0) to aws-sdk-core.rb:283:in 'initialize'` in [fips-integration-windows-2012r2](http://manhattan.ci.chef.co/job/chef-test/102/architecture=x86_64,platform=acceptance,project=chef,role=tester/artifact/chef-acceptance-data/logs/fips/converge/fips-integration-windows-2012r2.log) and `aws ssh connection timeout` in [chef-current-install-ubuntu-1404](http://manhattan.ci.chef.co/job/chef-test/102/architecture=x86_64,platform=acceptance,project=chef,role=tester/artifact/chef-acceptance-data/logs/basics/converge/chef-current-install-ubuntu-1404.log).

## Thu Jul 27 2016

* 11:48:00: @shain CCRs angrychef-nexus-7-builder-0c5c15, angrychef-ios_xr-6-builder-9724b5 and chef-nexus-7-builder-bf8ea8

## Thu Jul 28 2016

### 12.13.14 SUCCEEDS

* 21:00:21 - @mwrockx starts retry [12.13.14 #74 test 105](http://manhattan.ci.chef.co/job/chef-test/105/).
* 19:18:04 - [12.13.15 #74 succeeds](http://manhattan.ci.chef.co/job/chef-promote/41/).

github:
  - https://github.com/chef/chef/tree/v12.13.13
  - https://github.com/chef/chef/tree/v12.13.14

affected_versions:
  - project: chef
    version: 12.13.13
  - project: chef-12.13.14
: FIPS acceptance failures


  - Jul 25, 2016 6:20:08 PM - 12.13.13 kicked off
  - 12.13.13 failed build - http://manhattan.ci.chef.co/job/chef-build/212/ - git checkout timeout
  - 12.13.13 failed build - http://manhattan.ci.chef.co/job/chef-build/213/ - git checkout timeout
  - 12.13.13 failed build - http://manhattan.ci.chef.co/job/chef-build/214/ - git checkout timeout
  - 12.13.13 build success - http://manhattan.ci.chef.co/job/chef-build/219/

  CAUSE

  FAILURE
  - Jul 26, 2016 5:03:51 PM PST - 12.13.13 test 100 fails
    - undiagnosed issue #1:
http://manhattan.ci.chef.co/job/chef-test/100/architecture=x86_64,platform=acceptance,project=chef,role=tester/artifact/chef-acceptance-data/logs/fips/provision.log

  - Jul 26, 2016 1:07:51 PM PST - 12.13.13 test 102 fails
    - undiagnosed issue #2:
      http://manhattan.ci.chef.co/job/chef-test/102/architecture=x86_64,platform=acceptance,project=chef,role=tester/artifact/chef-acceptance-data/logs/fips/converge/fips-integration-windows-2012r2.log
      E, [2016-07-27T03:06:49.409105 #27501] ERROR -- fips-integration-windows-2012r2: ------Exception-------
      E, [2016-07-27T03:06:49.409141 #27501] ERROR -- fips-integration-windows-2012r2: Class: ArgumentError
      E, [2016-07-27T03:06:49.409167 #27501] ERROR -- fips-integration-windows-2012r2: Message: wrong number of arguments (1 for 0)
      E, [2016-07-27T03:06:49.409189 #27501] ERROR -- fips-integration-windows-2012r2: ----------------------
      E, [2016-07-27T03:06:49.409214 #27501] ERROR -- fips-integration-windows-2012r2: ------Backtrace-------
      E, [2016-07-27T03:06:49.409234 #27501] ERROR -- fips-integration-windows-2012r2: /home/jenkins/workspace/chef-test/architecture/x86_64/platform/acceptance/project/chef/role/tester/acceptance/vendor/bundle/ruby/2.1.0/gems/aws-sdk-core-2.4.2/lib/aws-sdk-core.rb:283:in `initialize'
      E, [2016-07-27T03:06:49.409254 #27501] ERROR -- fips-integration-windows-2012r2: /home/jenkins/workspace/chef-test/architecture/x86_64/platform/acceptance/project/chef/role/tester/acceptance/vendor/bundle/ruby/2.1.0/gems/aws-sdk-core-2.4.2/lib/aws-sdk-core.rb:283:in `new'
      E, [2016-07-27T03:06:49.409274 #27501] ERROR -- fips-integration-windows-2012r2: /home/jenkins/workspace/chef-test/architecture/x86_64/platform/acceptance/project/chef/role/tester/acceptance/vendor/bundle/ruby/2.1.0/gems/aws-sdk-core-2.4.2/lib/aws-sdk-core.rb:283:in `shared_config'
      E, [2016-07-27T03:06:49.409294 #27501] ERROR -- fips-integration-windows-2012r2: /home/jenkins/workspace/chef-test/architecture/x86_64/platform/acceptance/project/chef/role/tester/acceptance/vendor/bundle/ruby/2.1.0/gems/aws-sdk-core-2.4.2/lib/aws-sdk-core/shared_credentials.rb:25:in `initialize'
      E, [2016-07-27T03:06:49.409314 #27501] ERROR -- fips-integration-windows-2012r2: /home/jenkins/workspace/chef-test/architecture/x86_64/platform/acceptance/project/chef/role/tester/acceptance/vendor/bundle/ruby/2.1.0/gems/kitchen-ec2-1.0.1/lib/kitchen/driver/aws/client.rb:59:in `new'
    - machine failed to start, unknown reason:
      http://manhattan.ci.chef.co/job/chef-test/102/architecture=x86_64,platform=acceptance,project=chef,role=tester/artifact/chef-acceptance-data/logs/basics/converge/chef-current-install-ubuntu-1404.log
      I, [2016-07-27T03:07:51.998219 #28264]  INFO -- chef-current-install-ubuntu-1404: EC2 instance <i-0f068fa0> ready.
      D, [2016-07-27T03:07:51.998649 #28264] DEBUG -- chef-current-install-ubuntu-1404: [SSH] opening connection to ubuntu@10.194.9.189<{:user_known_hosts_file=>"/dev/null", :paranoid=>false, :port=>22, :compression=>false, :compression_level=>0, :keepalive=>true, :keepalive_interval=>60, :timeout=>15, :keys_only=>true, :keys=>["/home/jenkins/.ssh/jenkins.pem"], :auth_methods=>["publickey"]}>
      D, [2016-07-27T03:08:07.010116 #28264] DEBUG -- chef-current-install-ubuntu-1404: [SSH] connection failed (#<Net::SSH::ConnectionTimeout: Net::SSH::ConnectionTimeout>)
      I, [2016-07-27T03:08:07.010187 #28264]  INFO -- chef-current-install-ubuntu-1404: Waiting for SSH service on 10.194.9.189:22, retrying in 3 seconds


DIAGNOSIS
  - Jul 26, 2016 5:12 PM PST bot notifies #clients-pool of 12.13.14 build 100 failure: https://chefio.slack.com/archives/clients-pool/p1469578350001477
- Jul 26, 2016 5:37 PST Matt notices red on jenkins page “In the meantime I hit retry again because why not” https://chefio.slack.com/archives/clients-pool/p1469579847001483
  - Jul 26, 2016 7:33:32 PM - Matt ran 12.13.14 ad-hoc, succeeded: http://manhattan.ci.chef.co/job/chef-trigger-ad_hoc/107/
Matt retries 12.13.14: http://manhattan.ci.chef.co/job/chef-test/101
  - Jul 26, 2016 6:31 PM PST bot notifies #clients-pool of 12.13.14 build 101 failure: https://chefio.slack.com/archives/clients-pool/p1469583110001484
Matt retries 12.13.14: http://manhattan.ci.chef.co/job/chef-test/102
  - Jul 26, 2016 9:22 PM PST - bot notifies #clients-pool of 12.13.14 build 102 failure: https://chefio.slack.com/archives/clients-pool/p1469593346001489
- Jul 27, 2016 10:14 AM - Matt files COOL-465: https://chefio.atlassian.net/browse/COOL-465
- Jul 27, 2016 10:37:05 PM - Matt ran 12.13.13 ad-hoc, failed: http://manhattan.ci.chef.co/job/chef-build/222/
    - ios_xr-6: fakeroot due to non-CCR: http://manhattan.ci.chef.co/job/chef-build/222/architecture=x86_64,platform=ios_xr-6,project=chef,role=builder/console
    - nexus-7: fakeroot due to non-CCR: http://manhattan.ci.chef.co/job/chef-build/222/architecture=x86_64,platform=ios_xr-6,project=chef,role=builder/console
    - Matt's message: https://chefio.slack.com/archives/clients-pool/p1469652148001544
  - @shain fixes fakeroot - https://github.com/chef/omnibus-toolchain/pull/33
  - Matt retried 12.13.13 ad-hoc, succeeded: http://manhattan.ci.chef.co/job/chef-trigger-ad_hoc/108/
  - 12.13.13 passed
  - Jul 29, 2016 4:08:56 AM - incident over

  Remedied:
  - git checkout fixed when we switched from git to https protocol
  - support ticket filed with github
  - fakeroot removed from nexus and ios machines

  Future:
  - file a bug for undiagnosed issues
  - include link to build that failed in ticket
  - postmortem after each pipeline failure
  - #clients-pool-incident
  - take running notes as you go
  - not immediately clear which kitchen machines had failures, not super easy to get to the failures when you know
  - perhaps just run kitchen test?
  - Can we STOP writing "ERROR: Failed to post audit report to server. Saving report to /tmp/kitchen/cache/failed-audit-data.json"
  - jenkins_pipeline_report: extract kitchen failures
  - collect Cloud Trail Data (per Ryan Hass) so we can find out what happened to the instance
  - CCR builders more frequently
  - Make Slack show the correct dates on messages like https://chefio.slack.com/archives/clients-pool/p1469593346001489
  - Travis Omnibus build+install (cache?) on Linux + Windows

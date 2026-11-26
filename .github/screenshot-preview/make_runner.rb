require 'xcodeproj'

dir = ENV['RUNNER_DIR']
path = File.join(dir, 'PreviewRunner.xcodeproj')

project = Xcodeproj::Project.new(path)

host = project.new_target(:application, 'PreviewHost', :ios, '15.0')
host_group = project.main_group.new_group('PreviewHost', 'PreviewHost')
host.add_file_references([host_group.new_file('HostApp.swift')])

ui = project.new_target(:ui_test_bundle, 'PreviewUITests', :ios, '15.0')
ui_group = project.main_group.new_group('PreviewUITests', 'PreviewUITests')
ui.add_file_references([ui_group.new_file('ScreenshotTests.swift')])
ui.add_dependency(host)

host.build_configurations.each do |configuration|
  s = configuration.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.preview.host'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  s['MARKETING_VERSION'] = '1.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
end

ui.build_configurations.each do |configuration|
  s = configuration.build_settings
  s['PRODUCT_NAME'] = 'PreviewUITests'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.preview.PreviewUITests'
  s['TEST_TARGET_NAME'] = 'PreviewHost'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_test_target(ui)
scheme.set_launch_target(host)
scheme.save_as(path, 'PreviewUI', true)

project.save
puts 'Runner project created'
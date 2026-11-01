# Adds an XCUITest target (AppUITests) + shared scheme to the CI copy of the project only.
require 'xcodeproj'
require 'fileutils'

proj_path = ARGV[0] || 'App.xcodeproj'
src = ARGV[1] or abort 'usage: add_uitests.rb App.xcodeproj path/to/OrunUITests.swift'
root = File.dirname(File.expand_path(proj_path))
FileUtils.mkdir_p(File.join(root, 'AppUITests'))
FileUtils.cp(src, File.join(root, 'AppUITests', 'OrunUITests.swift'))

proj = Xcodeproj::Project.open(proj_path)
app = proj.targets.find { |t| t.name == 'App' } or abort 'App target missing'
t = proj.new_target(:ui_test_bundle, 'AppUITests', :ios, '16.0', nil, :swift)
group = proj.main_group.new_group('AppUITests', 'AppUITests')
ref = group.new_reference('OrunUITests.swift')
t.add_file_references([ref])
t.add_dependency(app)
t.build_configurations.each do |c|
  s = c.build_settings
  s['TEST_TARGET_NAME'] = 'App'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.orundocs.app.uitests'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['SWIFT_VERSION'] = '5.0'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
  s['CODE_SIGN_STYLE'] = 'Manual'
  s['DEVELOPMENT_TEAM'] = ''
end
proj.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(t)
scheme.set_launch_target(app)
scheme.save_as(proj_path, 'AppUITests', true)
puts 'AppUITests target + scheme added'

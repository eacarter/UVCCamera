Pod::Spec.new do |s|
  s.name             = 'uvccamera'
  s.version          = '0.0.1'
  s.summary          = 'Flutter UVC camera plugin'
  s.description      = <<-DESC
A Flutter plugin that provides camera access for USB and built-in cameras.
                       DESC
  s.homepage         = 'https://github.com/alexey-pelykh/UVCCamera'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'UvcCamera' => 'opensource@uvccamera.org' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end

Pod::Spec.new do |s|
  s.name             = 'GoAffPro'
  s.version          = '1.0.0'
  s.summary          = 'GoAffPro affiliate attribution tracking for iOS apps.'

  s.description      = <<-DESC
Tracks which affiliate referred each install and which affiliate's link led to each
conversion, using the platform install referrer with a server-side probabilistic fallback.
The wire payloads are byte-compatible with the SDKs for React Native, Android and Flutter.
                       DESC

  s.homepage         = 'https://goaffpro.com'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'GoAffPro' => 'support@goaffpro.com' }
  s.source           = { :git => 'https://github.com/goaffpro/ios-sdk.git', :tag => "ios-v#{s.version}" }

  s.ios.deployment_target = '13.0'
  s.swift_version         = '5.9'

  # `s.source_files` points at the SwiftPM source directory rather than a duplicated copy,
  # so there is exactly one set of sources to keep in sync. CocoaPods resolves this path
  # relative to the podspec, which is why the podspec must stay in sdks/ios/.
  s.source_files = 'Sources/GoAffPro/**/*.swift'

  s.frameworks = 'Foundation'
end

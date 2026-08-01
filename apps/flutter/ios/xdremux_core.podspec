Pod::Spec.new do |s|
  s.name             = 'xdremux_core'
  s.version          = '0.1.0'
  s.summary          = 'XDRemux Rust core + x265 static libraries.'
  s.description      = 'Vendored static archives for the XDRemux FFI bridge.'
  s.homepage         = 'https://example.com/xdremux'
  s.license          = { :type => 'MIT' }
  s.author           = { 'beet' => 'beet@example.com' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '15.0'

  # libxdremux_core.a embeds x265_helper.o, so only x265 + core are needed.
  # Vendored so the pod validates; the actual link flags (force-load from a
  # space-free dir) are set in the Podfile post_install, which overwrites the
  # auto -l flags CocoaPods generates from vendored_libraries.
  s.source_files = []
  s.vendored_libraries = [
    'Libraries/libx265.a',
    'Libraries/libxdremux_core.a',
  ]
  s.static_framework = true
  s.libraries = ['c++']
  s.frameworks = ['Security']
end

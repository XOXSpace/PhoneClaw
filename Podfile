platform :ios, '17.0'

target 'PhoneClaw' do
  # YAML 解析（SkillLoader 用于解析 SKILL.md frontmatter）
  pod 'Yams'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    end
  end
end

require 'yaml'

ROOT = File.expand_path('..', __dir__)

def check(condition, message)
  raise message unless condition
end

def entries(name)
  File.readlines(File.join(ROOT, name), encoding: 'UTF-8').map(&:strip).reject { |s| s.empty? || s.start_with?('#') }
end

template = YAML.load_file(File.join(ROOT, 'config-template.yml'))
groups = template.fetch('proxy-groups').map { |g| [g.fetch('name'), g] }.to_h
builtins = %w[DIRECT REJECT REJECT-DROP]
business = %w[默认代理 AI平台 开发交互 文件下载 电报服务 推特服务 谷歌服务 微软服务]
manual_groups = %w[默认手动 AI手动 开发手动 下载手动 电报手动 推特手动 谷歌手动 微软手动]
regions = %w[亚洲自动 香港节点 日本节点 台湾节点 新加坡组 韩国节点 美国节点 欧洲节点 其他地区]
auto_pools = %w[AI自动 优质自动 AI优选 优质优选 AI备用 优质备用 默认自动 流量自动]
expected_groups = business + auto_pools + %w[自建自动 落地服务 中转服务] + regions + manual_groups
check(template.fetch('proxy-groups').map { |g| g.fetch('name') } == expected_groups, 'Unexpected or duplicate groups')
visible_groups = business + ['中转服务'] + regions + manual_groups
hidden_groups = expected_groups - visible_groups
check(groups.values.reject { |g| g['hidden'] }.map { |g| g['name'] } == visible_groups, 'Unexpected dashboard groups')
check(groups.values.none? { |g| g['include-all'] }, 'Unrestricted node inclusion')

tests = {
  'AI自动' => ['https://api.openai.com/v1/models', 401],
  '优质自动' => ['https://github.com/robots.txt', 200],
  'AI优选' => ['https://api.openai.com/v1/models', 401],
  '优质优选' => ['https://github.com/robots.txt', 200],
  'AI备用' => ['https://api.openai.com/v1/models', 401],
  '优质备用' => ['https://github.com/robots.txt', 200],
  '默认自动' => ['https://cp.cloudflare.com', 204],
  '流量自动' => ['https://raw.githubusercontent.com/github/gitignore/main/Global/macOS.gitignore', 200],
  '自建自动' => ['https://www.gstatic.com/generate_204', 204],
  '落地服务' => ['https://www.apple.com/library/test/success.html', 200],
  '亚洲自动' => ['https://www.google.com/generate_204', 204],
  '欧洲节点' => ['https://detectportal.firefox.com/success.txt', 200],
  '其他地区' => ['https://connectivitycheck.gstatic.com/generate_204', 204]
}
regions[1..6].each { |name| tests[name] = tests.fetch('亚洲自动') }
check(groups.values.select { |g| g['type'] != 'select' }.map { |g| g['name'] }.sort == tests.keys.sort, 'Unexpected automatic groups')
tests.each do |name, (url, status)|
  g = groups.fetch(name)
  failover = %w[AI自动 优质自动].include?(name)
  check(g['type'] == (failover ? 'fallback' : 'url-test') && g['url'] == url && g['expected-status'] == status, "Invalid health check: #{name}")
  check(g['hidden'] == hidden_groups.include?(name) && (failover || !g['proxies']), "Invalid automatic group visibility or node candidates: #{name}")
  check(g['empty-fallback'] == 'REJECT', "Empty automatic pool must reject: #{name}")
  active = %w[AI自动 优质自动 AI优选 优质优选 AI备用 优质备用].include?(name)
  check(g['interval'] == (active ? 60 : 300) && g['lazy'] == !active, "Unexpected health-check scheduling: #{name}")
end
groups.each do |name, g|
  check(g['icon'].to_s.start_with?('https://github.com/Koolson/Qure/raw/master/IconSet/Color/'), "Missing group icon: #{name}")
end
%w[AI优选 优质优选].each do |name|
  g = groups[name]
  check(g['include-all-proxies'] && g['include-all-providers'] && !g['use'] && !g['proxies'] && g['filter'] == '优质', "Quality markers not collected: #{name}")
  check(Regexp.new(g['exclude-filter']).match?('流量 美国 01'), "Traffic node leaked into quality candidates: #{name}")
  %w[[优质]家宽落地美国01 [优质]美西DMIT美国01].each { |n| check(Regexp.new(g['filter']).match?(n) && !Regexp.new(g['exclude-filter']).match?(n), "Quality node rejected: #{n}") }
end
{'AI自动' => %w[AI优选 AI备用], '优质自动' => %w[优质优选 优质备用]}.each do |name, pools|
  g = groups.fetch(name)
  check(g['proxies'] == pools, "Failover must use preferred then backup pools: #{name}")
  check(!g['include-all-proxies'] && !g['include-all-providers'] && !g['use'] && !g['filter'] && !g['exclude-filter'], "Failover must not collect individual nodes: #{name}")
  pools.each { |pool| check(g.values_at('url', 'expected-status') == groups[pool].values_at('url', 'expected-status'), "Pool/failover probes differ: #{pool}") }
end
%w[AI备用 优质备用].each do |name|
  g = groups.fetch(name)
  check(g['include-all-proxies'] && g['include-all-providers'] && !g['use'] && !g['proxies'], "Backup omits ordinary nodes: #{name}")
  check(g['tolerance'] == 50, "Backup selection or tolerance changed: #{name}")
  ['普通 美国 01', '普通 日本 01'].each { |n| check(Regexp.new(g['filter']).match?(n) && !Regexp.new(g['exclude-filter']).match?(n), "Ordinary backup rejected: #{name}") }
  ['[优质] 美国 01', '流量 美国 01', '免费 美国 01', 'Free 美国 01', '未配置', '剩余100GB', '重置提示'].each { |n| check(Regexp.new(g['exclude-filter']).match?(n), "Invalid backup accepted: #{name}") }
end
business_defaults = %w[默认自动 AI自动 亚洲自动 默认自动 默认代理 默认代理 默认代理 默认代理]
business.zip(business_defaults, manual_groups).each do |name, default, manual_name|
  entry = groups.fetch(name)
  expected_options = [default, manual_name] + (regions - [default]) + ['DIRECT']
  check(entry['type'] == 'select' && entry['proxies'] == expected_options, "Business option order: #{name}")
  check(!entry['include-all-proxies'] && !entry['include-all-providers'] && !entry['use'], "Individual nodes listed in #{name}")

  manual = groups.fetch(manual_name)
  check(manual['type'] == 'select' && manual['proxies'].take(2) == [default, 'DIRECT'], "Manual default or direct option: #{manual_name}")
  check((manual['proxies'] & manual_groups).empty?, "Manual group shares selection with another group: #{manual_name}")
  check(manual['include-all-proxies'] && manual['include-all-providers'], "Manual nodes missing: #{manual_name}")
  include_pattern = Regexp.new(manual.fetch('filter'))
  exclude_pattern = Regexp.new(manual.fetch('exclude-filter'))
  check(include_pattern.match?('普通 香港 01') && !exclude_pattern.match?('普通 香港 01'), "Ordinary node unavailable in #{manual_name}")
  check(exclude_pattern.match?('剩余100GB') && exclude_pattern.match?('流量节点池未配置'), "Subscription metadata exposed in #{manual_name}")
end
ai_group = groups.fetch('AI手动')
ai_filter = Regexp.new(ai_group.fetch('filter'))
ai_exclude = Regexp.new(ai_group.fetch('exclude-filter'))
['普通 香港 01', '普通 日本 01', '[优质] 美国 01'].each do |name|
  check(ai_filter.match?(name) && !ai_exclude.match?(name), "AI manual selection hides #{name}")
end
['流量 美国 01', '免费 日本 01', 'Free 韩国 01', '剩余100GB'].each do |name|
  check(ai_exclude.match?(name), "AI manual selection includes #{name}")
end
%w[流量自动].each do |name|
  g = groups[name]
  check(!g['use'] && !g['proxies'] && g['include-all-proxies'] && g['include-all-providers'], "Traffic collection misses flattened or mixed subscriptions: #{name}")
  check(g['filter'] == '流量', "Traffic collection must require the name marker: #{name}")
  %w[流量香港01 低倍率流量美国01].each { |n| check(Regexp.new(g['filter']).match?(n) && !Regexp.new(g['exclude-filter']).match?(n), "Traffic node rejected: #{n}") }
  %w[剩余流量100GB 流量节点池未配置].each { |n| check(Regexp.new(g['exclude-filter']).match?(n), "Traffic metadata accepted: #{n}") }
  check(g['empty-fallback'] == 'REJECT', "Traffic pool must not fall back to DIRECT: #{name}")
end
provider_filter = Regexp.new(template.fetch('PProviders').fetch('filter'))
check(provider_filter.match?('流量 香港 01'), 'Subscription loader removes traffic nodes before grouping')
check(!provider_filter.match?('剩余流量 100GB'), 'Subscription loader accepts quota metadata')
(regions + %w[自建自动 默认自动 中转服务]).each do |name|
  g = groups.fetch(name)
  check(g['use'] == ['默认节点池'] && g['exclude-filter'].include?('流量') && g['exclude-filter'].include?('落地'), "Main pool isolation: #{name}")
end
check(groups['落地服务']['filter'] == '落地' && groups['落地服务']['exclude-filter'].include?('流量'), 'Landing pool isolation')
check(groups['中转服务']['proxies'] == regions + %w[自建自动 默认自动], 'Relay must only select ordinary routes')
filters = regions[1..-2].map { |name| groups.fetch(name).fetch('filter').sub(/\A\(\?i\)/, '') }
check(groups['其他地区']['filter'] == '(?i)^(?!.*(?:' + filters.join('|') + '))', 'Other must complement named regions')

visit = lambda do |name, stack|
  check(!stack.include?(name), "Group reference cycle: #{(stack + [name]).join(' -> ')}")
  (groups[name]['proxies'] || []).each do |child|
    check(groups.key?(child) || builtins.include?(child), "Missing group: #{child}")
    visit.call(child, stack + [name]) if groups.key?(child)
  end
end
groups.each_key { |name| visit.call(name, []) }

rules = template.fetch('rules')
providers = template.fetch('rule-providers')
rules.each do |r|
  parts = r.split(',')
  check(providers.key?(parts[1]), "Missing rule provider: #{parts[1]}") if parts[0] == 'RULE-SET'
  target = parts[-1] == 'no-resolve' ? parts[-2] : parts[-1]
  check(groups.key?(target) || builtins.include?(target), "Missing rule target: #{target}")
end
order = %w[aaa_block aaa_ads category-public-tracker private_domain private_ip lan aaa_direct aaa_direct_process aaa_ai aaa_traffic aaa_proxy category-ai-!cn microsoft google aaa_quality ai_suite google_ip apple-cn cloudflare-cn download cn_domain geolocation-!cn cn_ip]
actual = rules.grep(/^RULE-SET,/).map { |r| r.split(',')[1] }
check(actual == order && actual.sort == providers.keys.sort, 'Rule priority or provider usage changed')
check(rules.last == 'MATCH,默认代理', 'Unexpected final policy')

social_rules = %w[GEOSITE,telegram,电报服务 GEOIP,telegram,电报服务,no-resolve GEOSITE,twitter,推特服务]
social_rules.each do |rule|
  index = rules.index(rule)
  check(index && index > rules.index('RULE-SET,aaa_direct,DIRECT') && index < rules.index('RULE-SET,aaa_direct_process,DIRECT'), "Social routing priority: #{rule}")
end
Dir.glob(File.join(ROOT, '*.list')).each do |file|
  rows = entries(File.basename(file))
  check(rows.uniq == rows, "Duplicate rules: #{File.basename(file)}")
end
check(entries('ai.list').none? { |r| r.start_with?('DOMAIN-KEYWORD,') || r == 'DOMAIN,api.github.com' }, 'Overbroad local AI rules')
vendor_order = %w[RULE-SET,aaa_ai,AI平台 RULE-SET,aaa_traffic,文件下载 RULE-SET,category-ai-!cn,AI平台 GEOSITE,github,开发交互 RULE-SET,microsoft,微软服务 RULE-SET,google,谷歌服务 RULE-SET,aaa_quality,开发交互 RULE-SET,ai_suite,AI平台 RULE-SET,google_ip,谷歌服务,no-resolve]
check(rules.select { |r| vendor_order.include?(r) } == vendor_order, 'AI, GitHub, vendor or fallback routing changed')
%w[DOMAIN,js.stripe.com DOMAIN-SUFFIX,intercom.io].each do |r|
  check(entries('quality.list').include?(r), "Missing shared-service exception: #{r}")
end
check(entries('direct.list').none? { |r| %w[mirror ntp ghproxy ghfast].any? { |s| r == "DOMAIN-KEYWORD,#{s}" } }, 'Overbroad direct keyword')
%w[Bob Postman jetbrains-toolbox].each { |p| check(!entries('dicrec-process.list').include?("PROCESS-NAME,#{p}"), "Unconditional direct process: #{p}") }
git_rule = entries('traffic.list').find { |r| r.include?('PROCESS-NAME-REGEX,') }
pattern = git_rule.split('PROCESS-NAME-REGEX,', 2)[1].split('),(DOMAIN-SUFFIX,', 2)[0]
git_process = Regexp.new(pattern)
%w[git git-remote-http git-remote-https git-lfs git.exe].each { |p| check(git_process.match?(p), "Missing Git process: #{p}") }
%w[curl studio idea gitbook].each { |p| check(!git_process.match?(p), "Overbroad Git process: #{p}") }
check(git_rule.end_with?('(DOMAIN-SUFFIX,github.com))'), 'Git process must be limited to GitHub')
check(!entries('traffic.list').include?('DOMAIN-SUFFIX,github.com'), 'Ordinary GitHub must not be classified as bulk traffic')
samples = %w[香港01 JP-01 台湾01 SG-01 韩国01 US-01 德国01 澳大利亚01]
regions.drop(1).zip(samples).each do |expected, sample|
  matches = regions.drop(1).select { |name| Regexp.new(groups[name]['filter']).match?(sample) }
  check(matches == [expected], "Unexpected region for #{sample}: #{matches}")
end
%w[Russia01 加拿大01 澳门01].zip(%w[欧洲节点 其他地区 其他地区]).each do |sample, expected|
  check(Regexp.new(groups[expected]['filter']).match?(sample), "Region missing #{sample}")
end

text = File.read(File.join(ROOT, 'config-template.yml'))
mirror = text.gsub('https://github.com', 'https://gh-proxy.com/https://github.com').gsub('https://gh-proxy.com/https://github.com/robots.txt', 'https://github.com/robots.txt')
check(File.read(File.join(ROOT, 'config-template-mirror.yml')) == mirror, 'Mirror template is out of sync or mirrors a business probe')
template.fetch('proxy-providers').each do |name, p|
  check(p['type'] == 'inline' && !p['url'] && p['payload'].all? { |node| node['type'] == 'reject' }, "Private subscription leaked into template: #{name}")
end
check(template.fetch('proxy-providers').keys == %w[默认节点池 优质节点池 流量节点池], 'Unexpected node pool names')
source_path = File.join(ROOT, 'config.yml')
if File.exist?(source_path)
  source = YAML.load_file(source_path)
  check(source.fetch('proxy-providers').fetch('默认节点池')['proxy'] == 'DIRECT', 'Main subscription bootstrap depends on itself')
  %w[proxy-groups rule-providers rules].each { |k| check(source[k] == template[k], "Source/template mismatch: #{k}") }
end
puts "PASS: #{groups.length} groups (#{visible_groups.length} visible), #{rules.length} rules, pool isolation, Git boundaries and template synchronization"

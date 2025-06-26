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
expected_groups = %w[AI平台 优质服务 流量服务 默认代理 AI自动 优质自动 AI优选 优质优选 AI备用 优质备用 默认自动 流量自动 自建自动 落地服务 中转服务 亚洲节点 美洲节点 欧洲节点 其他地区]
check(groups.keys == expected_groups, 'Unexpected or duplicate proxy groups')
hidden_groups = %w[AI自动 优质自动 AI优选 优质优选 AI备用 优质备用 默认自动 流量自动]
visible_groups = %w[AI平台 优质服务 流量服务 默认代理 自建自动 落地服务 中转服务 亚洲节点 美洲节点 欧洲节点 其他地区]
check(groups.values.select { |g| g['hidden'] }.map { |g| g['name'] } == hidden_groups, 'Unexpected hidden groups')
check(groups.values.reject { |g| g['hidden'] }.map { |g| g['name'] } == visible_groups, 'Visible group order changed')
check(visible_groups.all? { |name| name.length == 4 }, 'Visible group names must have four characters')
check(groups.values.none? { |g| g['include-all'] }, 'Unrestricted node inclusion')
scanning_groups = %w[AI平台 优质服务 流量服务 默认代理 AI优选 优质优选 AI备用 优质备用 流量自动]
check(groups.values.select { |g| g['include-all-providers'] }.map { |g| g['name'] }.sort == scanning_groups.sort, 'Unexpected provider-wide node collection')

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
  '亚洲节点' => ['https://www.google.com/generate_204', 204],
  '美洲节点' => ['https://cp.cloudflare.com/generate_204', 204],
  '欧洲节点' => ['https://detectportal.firefox.com/success.txt', 200],
  '其他地区' => ['https://connectivitycheck.gstatic.com/generate_204', 204]
}
check(groups.values.select { |g| g['type'] != 'select' }.map { |g| g['name'] } == tests.keys, 'Unexpected automatic groups')
check(tests.reject { |name,_| %w[AI优选 优质优选 AI备用 优质备用].include?(name) }.values.map(&:first).uniq.length == tests.length - 4, 'Unrelated automatic groups must use independent probe URLs')
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
  check(g['filter'] == groups['AI平台']['filter'] && g['tolerance'] == 50, "Backup selection or tolerance changed: #{name}")
  ['普通 美国 01', '普通 日本 01'].each { |n| check(Regexp.new(g['filter']).match?(n) && !Regexp.new(g['exclude-filter']).match?(n), "Ordinary backup rejected: #{name}") }
  ['[优质] 美国 01', '流量 美国 01', '免费 美国 01', 'Free 美国 01', '未配置', '剩余100GB', '重置提示'].each { |n| check(Regexp.new(g['exclude-filter']).match?(n), "Invalid backup accepted: #{name}") }
end
shared = %w[AI自动 优质自动 默认自动 流量自动 自建自动 落地服务 亚洲节点 美洲节点 欧洲节点 其他地区]
{'AI平台' => 'AI自动', '优质服务' => '优质自动', '流量服务' => '流量自动', '默认代理' => '默认自动'}.each do |name, automatic|
  g = groups[name]
  check(g['proxies'].first == automatic, "Wrong automatic default: #{name}")
  check(g['type'] == 'select' && g['proxies'] == [automatic] + (shared - [automatic]), "Usage group candidates differ: #{name}")
  check(g['proxies'].none? { |candidate| Regexp.new(g['exclude-filter']).match?(candidate) }, "Node filter also hides a group strategy: #{name}")
  check(g['include-all-proxies'] && g['include-all-providers'], "Direct node selection missing: #{name}")
  %w[[优质]落地美国01 默认香港01].each do |n|
    check(Regexp.new(g['filter']).match?(n) && !Regexp.new(g['exclude-filter']).match?(n), "Usage group rejects actual node #{n}: #{name}")
  end
  ['流量美国01', '免费香港01', 'Free 美国01', '[FREE] 日本01'].each do |n|
    accepted = Regexp.new(g['filter']).match?(n) && !Regexp.new(g['exclude-filter']).match?(n)
    check(accepted == !%w[AI平台 优质服务].include?(name), "Incorrect direct traffic/free node visibility in #{name}: #{n}")
  end
  %w[流量节点池未配置 剩余流量100GB].each { |n| check(Regexp.new(g['exclude-filter']).match?(n), "Usage group accepts metadata: #{name}") }
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
%w[亚洲节点 美洲节点 欧洲节点 其他地区 自建自动 默认自动 中转服务].each do |name|
  g = groups[name]
  check(g['use'] == ['默认节点池'] && g['exclude-filter'].include?('流量') && g['exclude-filter'].include?('落地'), "Main/relay pool isolation: #{name}")
end
check(groups['自建自动']['filter'] == '自建', 'Self-built pool must require its name marker')
check(groups['落地服务']['filter'] == '落地' && groups['落地服务']['use'] == ['默认节点池'] && groups['落地服务']['exclude-filter'].include?('流量'), 'Landing pool isolation changed')
check(groups['中转服务']['proxies'] == %w[自建自动 默认自动 亚洲节点 美洲节点 欧洲节点 其他地区], 'Relay may not select landing/quality/usage groups')
region_filters = %w[亚洲节点 美洲节点 欧洲节点].map { |name| groups[name]['filter'].sub(/\A\(\?i\)/, '') }
check(groups['其他地区']['filter'] == '(?i)^(?!.*(?:' + region_filters.join('|') + '))', 'Other-region filter is not the complement of the three region filters')

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
order = %w[aaa_block aaa_ads category-public-tracker private_domain private_ip lan aaa_direct aaa_direct_process aaa_ai aaa_traffic aaa_quality aaa_proxy ai_suite category-ai-!cn microsoft google google_ip apple-cn cloudflare-cn download cn_domain geolocation-!cn cn_ip]
actual = rules.grep(/^RULE-SET,/).map { |r| r.split(',')[1] }
check(actual == order && actual.sort == providers.keys.sort, 'Rule priority or provider usage changed')
check(rules.last == 'MATCH,默认代理', 'Unexpected final policy')

Dir.glob(File.join(ROOT, '*.list')).each do |file|
  rows = entries(File.basename(file))
  check(rows.uniq == rows, "Duplicate rules: #{File.basename(file)}")
end
check(entries('ai.list').none? { |r| r.start_with?('DOMAIN-KEYWORD,') || r == 'DOMAIN,api.github.com' }, 'Overbroad local AI rules')
check(entries('quality.list').include?('DOMAIN,api.github.com'), 'Ordinary GitHub API must use quality service')
%w[DOMAIN,js.stripe.com DOMAIN-SUFFIX,intercom.io DOMAIN,fonts.googleapis.com].each do |r|
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
{'亚洲节点' => ['香港 01', '日本 01', 'SG 01', '澳门 01', '沙特阿拉伯 01'], '美洲节点' => ['美国 01', '加拿大 01', 'US 01', '哥伦比亚 01'], '欧洲节点' => ['德国 01', '英国 01', 'Russia 01', '乌克兰 01']}.each do |name, samples|
  regexp = Regexp.new(groups[name]['filter'])
  samples.each { |s| check(regexp.match?(s), "Region filter misses #{s}") }
end
check(!Regexp.new(groups['美洲节点']['filter']).match?('Russia 01'), 'US must not match Russia')
other = Regexp.new(groups['其他地区']['filter'])
['渔云 澳大利亚 01', 'iKuuu 南非 01', '默认 未知地区 01'].each { |n| check(other.match?(n), "Other-region filter misses #{n}") }
['渔云 香港 01', '雪山 美国 01', '默认 德国 01', '自建 SG 01'].each { |n| check(!other.match?(n), "Known region leaked into other: #{n}") }

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

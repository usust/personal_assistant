#!/usr/bin/env python3
"""从监管总局表格 PDF 生成离线机构目录；依赖 pdfplumber 和 macOS Swift，不在 App 运行时抓取。"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import pdfplumber

ROOT = Path(__file__).resolve().parents[1]
GROUPS = {
    '开发性金融机构': 'policy', '政策性银行': 'policy', '国有大型商业银行': 'national',
    '股份制商业银行': 'jointStock', '城市商业银行': 'city', '民营银行': 'digital',
    '直销银行': 'digital', '外资法人银行': 'foreign', '住房储蓄银行': 'housing',
    '农村商业银行': 'ruralCommercial', '农村合作银行': 'ruralCooperative',
    '农村信用社': 'ruralCredit', '农村资金互助社': 'mutual', '村镇银行': 'village',
    '外国及港澳台银行分行': 'foreignBranch',
}
# 固定快照的完整计数包括非银行类，更新源文件时必须同时人工核对这些断言。
EXPECTED = {'开发性金融机构': 1, '政策性银行': 2, '国有大型商业银行': 6, '股份制商业银行': 12,
    '城市商业银行': 123, '民营银行': 19, '外资法人银行': 41, '住房储蓄银行': 1, '直销银行': 1,
    '农村商业银行': 1398, '农村合作银行': 18, '农村信用社': 336, '农村资金互助社': 4, '村镇银行': 1177,
    '信托公司': 67, '金融资产管理公司': 5, '金融租赁公司': 70, '企业集团财务公司': 232,
    '消费金融公司': 31, '汽车金融公司': 25, '货币经纪公司': 6, '其他金融机构': 44}

# 提取六列表格；参数：path 为官方 PDF，count 为期望总行数；返回：原始记录列表；缺列、漏行、重号或缺失字段时抛错，禁止静默跳过。
def extract(path, count):
    rows = []
    with pdfplumber.open(path) as pdf:
        if '2025年12月31日' not in pdf.pages[0].extract_text().replace(' ', ''):
            raise ValueError('源日期不是锁定的 2025-12-31，请先更新快照规范')
        for page in pdf.pages:
            for table in page.extract_tables():
                for row in table:
                    if row[0] == '序号':
                        continue
                    if len(row) != 6 or not row[0] or not row[0].isdigit() or any(c is None for c in row):
                        raise ValueError(f'无法识别的表格行：{row}')
                    rows.append([c.replace('\n', ' ' if i == 2 else '').strip() for i, c in enumerate(row)])
            page.close()
    if [int(r[0]) for r in rows] != list(range(1, count + 1)):
        raise ValueError('序号不连续或总数与官方不符')
    if len({r[3] for r in rows}) != count or any(not re.fullmatch(r'[A-Z]\d{4}[A-Z]\d{9}', r[3]) for r in rows):
        raise ValueError('机构编码重复或格式无效')
    return rows

# 生成显示简称；参数：name 为官方中文全称；返回：仅移除结尾公司法律形式后的名称，不删除分行或地域；无副作用。
def short_name(name):
    return re.sub(r'(股份有限公司|有限责任公司|有限公司)$', '', name)

# 构造本地产品选项；参数：key/name/type/group/icon 为标识、名称、服务端类型、分组、图标，aliases 为别名，credit 为信用标记；返回：可编码字典；无副作用。
def product(key, name, kind, group, icon, aliases=(), credit=False):
    return dict(id=key, name=name, type=kind, institution=name, icon=icon, aliases=list(aliases),
                group=group, region='', regulatoryType='', isCredit=credit, searchKey='')

# 导入并生成可复现资源；参数：通过命令行指定两份 PDF 和可选输出目录；返回：无；校验失败退出，成功写 JSON、来源审计及拼音索引。
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--banks', type=Path, required=True)
    parser.add_argument('--branches', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'PersonalAssistant/Resources/AccountProviders.json')
    parser.add_argument('--audit-output', type=Path, default=ROOT / 'Documentation/AccountProviders.audit.json')
    args = parser.parse_args()
    banks, branches = extract(args.banks, 3619), extract(args.branches, 114)
    assert Counter(r[4] for r in banks) == EXPECTED, '类别计数与官方不符'
    assert Counter(r[4] for r in branches) == {'外国及港澳台银行分行': 114}
    overrides = json.loads((ROOT / 'Scripts/Data/provider-overrides.json').read_text())
    overrides = {v['matchName']: v for v in overrides}
    providers = []
    for row in banks + branches:
        _, official, english, code, category, regulator = row
        if category not in GROUPS:
            continue
        name = short_name(official)
        override = overrides.get(name, {})
        display = override.get('name', name)
        aliases = list(dict.fromkeys([name, english, *override.get('aliases', []),
            name.replace('农村商业银行', '农商银行'), name.replace('农村信用合作联社', '农信联社')]))
        providers.append(dict(id='nfra-' + code, name=display, type='bank', institution=official,
            icon=override.get('icon', 'bank'), aliases=[a for a in aliases if a and a != '无'],
            group=GROUPS[category], region=regulator.replace('金融监管局', '').replace('金融监管总局', ''),
            regulatoryType=category, isCredit=False, searchKey=''))
    assert set(overrides) <= {short_name(p['institution']) for p in providers}, '存在未匹配的品牌覆盖项'
    providers += [
        product('alipay', '支付宝', 'alipay', 'wallet', 'alipay', ['alipay']),
        product('wechat', '微信支付', 'wechat', 'wallet', 'wechat', ['微信', '零钱', 'wechat', 'weixin']),
        product('huabei', '花呗', 'other', 'credit', 'credit-card', ['蚂蚁花呗', '支付宝花呗', 'huabei'], True),
        product('baitiao', '京东白条', 'other', 'credit', 'credit-card', ['白条', 'JD', 'baitiao'], True),
        product('jiebei', '借呗', 'other', 'credit', 'credit-card', ['蚂蚁借呗', '支付宝借呗'], True),
        product('jintiao', '京东金条', 'other', 'credit', 'credit-card', ['金条', 'JD'], True),
        product('weilidai', '微粒贷', 'other', 'credit', 'credit-card', ['微众', '微信微粒贷', 'QQ微粒贷'], True),
        product('cash', '现金', 'cash', 'other', 'cash'),
        product('savings', '储蓄账户', 'savings', 'other', 'savings', ['储蓄']),
        product('investment', '投资账户', 'investment', 'other', 'investment', ['证券', '基金', '股票', '投资']),
        product('other', '其他账户', 'other', 'other', 'wallet', ['其他']),
    ]
    counts = dict(Counter(p['group'] for p in providers if p['type'] == 'bank'))
    sources = []
    for path, doc_id, filename, count in [(args.banks, 1268142, '1dcdad9de86f4d9d889356bb64cb313e.pdf', 3619),
                                          (args.branches, 1268146, 'a7652d31c3114831a2c97bb7255bd299.pdf', 114)]:
        sources.append(dict(url='https://www.nfra.gov.cn/chinese/docfile/2026/' + filename,
            article=f'https://www.nfra.gov.cn/cn/view/pages/governmentDetail.html?docId={doc_id}&generaltype=1&itemId=863',
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(), totalRows=count))
    document = dict(asOf='2025-12-31', retrievedAt='2026-09-27', publishedAt='2026-08-14',
        bankCount=sum(counts.values()), counts=counts, sources=sources, providers=providers)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # 先写临时文件并生成索引，通过全部检查后再替换，失败不会留下半份生产目录。
    with tempfile.TemporaryDirectory() as scratch:
        temporary = Path(scratch) / 'catalog.json'
        temporary.write_text(json.dumps(document, ensure_ascii=False))
        env = dict(os.environ, DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
        subprocess.run(['xcrun', 'swift', '-module-cache-path', scratch + '/cache', str(ROOT / 'Scripts/BuildProviderSearch.swift'), str(temporary)], env=env, check=True)
        args.output.write_bytes(temporary.read_bytes() + b'\n')
    audit = dict(asOf=document['asOf'], counts=counts, excludedCounts={k:v for k,v in EXPECTED.items() if k not in GROUPS}, sources=sources,
                 bankRows=banks, branchRows=branches)
    args.audit_output.parent.mkdir(parents=True, exist_ok=True)
    args.audit_output.write_text(json.dumps(audit, ensure_ascii=False, indent=2) + '\n')
    print(f'已导入 {sum(counts.values())} 个银行／合作机构和分行，{len(providers)} 个账户机构选项；分类：{counts}')

if __name__ == '__main__':
    main()

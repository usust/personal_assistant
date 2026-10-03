export function money(value: string | number | null | undefined) {
  const raw = String(value ?? '0').trim()
  const match = raw.match(/^(-?)(\d+)(?:\.(\d+))?$/)
  if (!match) return '￥0.00'
  const whole = (match[2]!.replace(/^0+(?=\d)/, '') || '0').replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  const fraction = `${match[3] ?? ''}00`.slice(0, 2)
  return `${match[1] ? '-' : ''}￥${whole}.${fraction}`
}

export function percent(value: string | number | null | undefined) {
  if (value === null || value === undefined || value === '') return '--'
  return `${Number(value).toFixed(2)}%`
}

export function today() {
  const date = new Date()
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
}

export function ratio(numerator: string | number, denominator: string | number) {
  const parse = (value: string | number) => {
    const match = String(value).trim().match(/^(-?)(\d+)(?:\.(\d{1,2}))?$/)
    if (!match) return 0n
    const amount = BigInt(match[2]!) * 100n + BigInt(`${match[3] ?? ''}00`.slice(0, 2))
    return match[1] ? -amount : amount
  }
  const top = parse(numerator)
  const base = parse(denominator)
  if (base <= 0n || top <= 0n) return 0
  const hundredths = (top * 10000n + base / 2n) / base
  return Number(hundredths) / 100
}

export function sumMoney(values: string[]) {
  let cents = 0n
  for (const value of values) {
    const match = String(value).trim().match(/^(-?)(\d+)(?:\.(\d{1,2}))?$/)
    if (!match) continue
    const minor = `${match[3] ?? ''}00`.slice(0, 2)
    const amount = BigInt(match[2]!) * 100n + BigInt(minor)
    cents += match[1] ? -amount : amount
  }
  const negative = cents < 0n
  if (negative) cents = -cents
  const result = `${cents / 100n}.${String(cents % 100n).padStart(2, '0')}`
  return negative ? `-${result}` : result
}

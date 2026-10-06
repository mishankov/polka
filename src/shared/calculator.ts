import { convertUnits } from './unit-conversions';
import { convertTimeZones } from './time-zone-conversions';

export type CalculationContext = { now?: Date; sourceDate?: string };

export type Calculation =
  | {
      status: 'result';
      expression: string;
      value: string;
      conversion?: 'unit' | 'time-zone';
      interpretation?: string;
      displayValue?: string;
      sourceDate?: string;
    }
  | { status: 'incomplete'; expression: string; message?: string }
  | { status: 'error'; expression: string; message: string };

class IncompleteExpression extends Error {}

/** A bounded arithmetic grammar, never JavaScript evaluation. Percent means / 100. */
export function calculate(
  query: string,
  context: CalculationContext = {},
): Calculation | undefined {
  const expression = query.trim();
  const conversion = convertTimeZones(expression, context) ?? convertUnits(expression);
  if (conversion) return conversion;
  const source = expression
    .replace(/^=\s*/, '')
    .replace(/[×хx]/g, '*')
    .replace(/÷/g, '/')
    .replace(/−/g, '-')
    .replace(/,/g, '.')
    .replace(/%\s*(?:of|от)\s*/gi, '% * ');
  if (!source || !/^[\d\s.eE+\-*/^()%]+$/.test(source)) return undefined;
  if (!expression.startsWith('=') && !/[+\-*/^%]/.test(source)) return undefined;
  if (source.length > 512)
    return { status: 'error', expression, message: 'Слишком длинное выражение' };
  const tokens = source.match(/(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[^\s]/g) || [];
  let position = 0;
  const peek = () => tokens[position];
  const take = (token: string) => {
    if (peek() !== token) return false;
    position++;
    return true;
  };
  function primary(): number {
    if (peek() === undefined) throw new IncompleteExpression();
    if (take('(')) {
      const value = sum();
      if (!take(')')) {
        if (peek() === undefined) throw new IncompleteExpression();
        throw Error('Проверьте скобки');
      }
      return value;
    }
    const token = tokens[position++];
    if (!/^(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(token))
      throw Error('Проверьте выражение');
    return Number(token);
  }
  function power(): number {
    let value = primary();
    if (take('%')) value /= 100;
    if (take('^')) value **= unary();
    return value;
  }
  function unary(): number {
    if (take('+')) return unary();
    if (take('-')) return -unary();
    return power();
  }
  function product(): number {
    let value = unary();
    while (peek() === '*' || peek() === '/') {
      const operator = tokens[position++];
      const right = unary();
      if (operator === '/' && right === 0) throw Error('На ноль делить нельзя');
      value = operator === '*' ? value * right : value / right;
    }
    return value;
  }
  function sum(): number {
    let value = product();
    while (peek() === '+' || peek() === '-') {
      const operator = tokens[position++];
      const right = product();
      value = operator === '+' ? value + right : value - right;
    }
    return value;
  }
  try {
    const result = sum();
    if (position !== tokens.length) throw Error('Проверьте выражение');
    if (!Number.isFinite(result)) throw Error('Результат вне допустимого диапазона');
    // Avoid exposing binary floating-point noise such as 0.30000000000000004.
    return { status: 'result', expression, value: String(Number(result.toPrecision(15))) };
  } catch (error) {
    return error instanceof IncompleteExpression
      ? { status: 'incomplete', expression }
      : { status: 'error', expression, message: (error as Error).message };
  }
}

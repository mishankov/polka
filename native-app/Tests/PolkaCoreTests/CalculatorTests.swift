import XCTest

@testable import PolkaCore

final class CalculatorTests: XCTestCase {
  override func setUp() {
    super.setUp()
    AppLocalization.configure(.russian)
  }
  override func tearDown() {
    AppLocalization.configure(.system)
    super.tearDown()
  }
  private let now = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!
  func testShippingArithmeticAndUnitExamples() {
    let pairs: [(String, String)] = [
      ("1250 * 3", "3750"),
      ("(450 + 180) / 2", "315"),
      ("2 + 3 * 4", "14"),
      ("-2^2", "-4"),
      ("(-2)^2", "4"),
      ("2^3^2", "512"),
      ("2^-3", "0.125"),
      ("1,5 + 2.5", "4"),
      ("0.1 + 0.2", "0.3"),
      ("3 × 4 − 2", "10"),
      ("12 ÷ 3", "4"),
      ("2x3", "6"),
      ("15% of 240", "36"),
      ("15% от 240", "36"),
      ("240 * 15%", "36"),
      ("100 + 10%", "100.1"),
      ("1e3 / 2", "500"),
      ("= 42", "42"),
      ("1 - 1", "0"),
      ("(-0)", "0"),
      ("10 inches in cm", "25.4 cm"),
      ("10 дюймов в сантиметры", "25.4 cm"),
      ("1,5 км в м", "1500 m"),
      (".5 m to mm", "500 mm"),
      ("2,5kg in g", "2500 g"),
      ("1 foot in inches", "12 in"),
      ("1 yard in ft", "3 ft"),
      ("1 mi in km", "1.609344 km"),
      ("1 lb in kg", "0.45359237 kg"),
      ("16 oz in lb", "1 lb"),
      ("1 metric ton in kg", "1000 kg"),
      ("1 тонна в кг", "1000 kg"),
      ("1 mg in g", "0.001 g"),
      ("90 min in hours", "1.5 h"),
      ("90 минут в часы", "1.5 h"),
      ("1 day in h", "24 h"),
      ("1 неделя в дни", "7 d"),
      ("1 second in ms", "1000 ms"),
      ("0 °C in °F", "32 °F"),
      ("32 F in C", "0 °C"),
      ("100 celsius to fahrenheit", "212 °F"),
      ("273,15 K в цельсия", "0 °C"),
      ("0 K in °F", "-459.67 °F"),
      ("-40 c in f", "-40 °F"),
      ("−40 C in F", "-40 °F"),
      ("-273.15 c in k", "0 K"),
      ("-459.67 f in k", "0 K"),
      ("-2 m in cm", "-200 cm"),
      ("-0 m in cm", "0 cm"),
      ("1e3 m in km", "1 km"),
      ("1e-20 c in c", "1e-20 °C"),
      ("  10 CM IN M  ", "0.1 m"),
      ("1 с в мин", "0.0166666666667 min"),
      ("0 с в °F", "32 °F"),
      ("100 метров в сантиметрах", "10000 cm"),
      ("100 метров в сантиметра", "10000 cm"),
      ("100 сантиметров в метрах", "1 m"),
      ("1 км в миллиметрах", "1000000 mm"),
      ("1000 м в километрах", "1 km"),
      ("1 ft в дюймах", "12 in"),
      ("1 yd в футах", "3 ft"),
      ("3 ft в ярдах", "1 yd"),
      ("1609,344 м в милях", "1 mi"),
      ("1 г в миллиграммах", "1000 mg"),
      ("1 кг в граммах", "1000 g"),
      ("1000 г в килограммах", "1 kg"),
      ("1000 кг в тоннах", "1 t"),
      ("1 lb в унциях", "16 oz"),
      ("16 oz в фунтах", "1 lb"),
      ("1 с в миллисекундах", "1000 ms"),
      ("1 мин в секундах", "60 s"),
      ("1 ч в минутах", "60 min"),
      ("90 минут в часах", "1.5 h"),
      ("48 ч в днях", "2 d"),
      ("48 ч в сутках", "2 d"),
      ("14 дней в неделях", "2 wk"),
      ("0 °C в кельвинах", "273.15 K"),
      ("32 °F в градусах Цельсия", "0 °C"),
      ("0 градусов Цельсия в градусах Фаренгейта", "32 °F"),
      ("1 метром в сантиметрах", "100 cm"),
    ]
    for (query, expected) in pairs {
      let actual = Calculator.calculate(query, context: CalculationContext(now: now))
      XCTAssertEqual(actual?.status, .result, query)
      XCTAssertEqual(actual?.value, expected, query)
    }
  }
  func testInvalidIncompleteAndNonCalculations() {
    for query in ["12 +", "(2 + 3", "2 ^", "10 * -", "10 inches in", "18:00 Moscow in"] {
      XCTAssertEqual(Calculator.calculate(query)?.status, .incomplete, query)
    }
    for query in [
      "1/0", "0/0", "2^^3", "1 2 + 3", "2(3+4)", "2%%", "10^1000", "(-1)^0.5",
      String(repeating: "1+", count: 300), "10 kg in cm", "1 ton in kg", "1 month in days",
      "1 с в с", "1 m in furlongs", "-1 K in C", "-1e-11 K in K", "-274 C in F", "1e309 m in cm",
      "1e308 km in mm", "1 m in " + String(repeating: "m", count: 600),
    ] { XCTAssertEqual(Calculator.calculate(query)?.status, .error, String(query.prefix(60))) }
    for query in [
      "", "Safari", "1Password", "42", "https://example.com", "process.exit()", "2+alert(1)",
      "100 документов в папках", "10 notes in Safari", "meet in London", "18:00 meeting notes",
      String(repeating: "1", count: 10000),
    ] { XCTAssertNil(Calculator.calculate(query), String(query.prefix(60))) }
  }
  func testTimeDatesOffsetsAndDeterministicToday() {
    for (query, expected) in [
      ("2026-07-15 18:00 Moscow in London", "16:00 · 2026-07-15 · Лондон (UTC+01:00)"),
      ("2026-01-15 18:00 Moscow in London", "15:00 · 2026-01-15 · Лондон (UTC+00:00)"),
      ("18:00 Москва в Лондоне 15.01.2026", "15:00 · 2026-01-15 · Лондон (UTC+00:00)"),
      (
        "1900-01-01 18:00 UTC in Europe/Moscow",
        "20:30:17 · 1900-01-01 · Europe/Moscow (UTC+02:30:17)"
      ),
      ("1900-01-01 18:00 UTC+02:30:17 in UTC", "15:29:43 · 1900-01-01 · UTC+00:00 (UTC+00:00)"),
      ("2026-07-15 18:00 UTC in Asia/Kathmandu", "23:45 · 2026-07-15 · Asia/Kathmandu (UTC+05:45)"),
      ("2026-01-01 01:00 Tokyo in New York", "11:00 · 2025-12-31 · Нью-Йорк (UTC−05:00)"),
      ("2026-12-31 23:30 UTC-12 in UTC+14", "01:30 · 2027-01-02 · UTC+14:00 (UTC+14:00)"),
    ] {
      XCTAssertEqual(
        Calculator.calculate(query, context: CalculationContext(now: now))?.value, expected, query)
    }
    let result = Calculator.calculate(
      "18:00 New York in Tokyo",
      context: CalculationContext(now: ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z")!))!
    XCTAssertEqual(result.sourceDate, "2025-12-31")
    XCTAssertEqual(result.value, "08:00 · 2026-01-01 · Токио (UTC+09:00)")
    XCTAssertTrue(result.interpretation!.contains("сегодня в исходном поясе"))
    XCTAssertTrue(result.interpretation!.contains("+1 дн."))
    XCTAssertEqual(
      Calculator.calculate(
        result.expression, context: CalculationContext(now: now, sourceDate: result.sourceDate))?
        .value, result.value)
  }
  func testDSTGapsOverlapsAndInvalidInputs() {
    for query in [
      "2026-03-08 02:30 New York in UTC", "2026-11-01 01:30 New York in UTC",
      "2026-03-29 01:30 London in UTC", "2026-10-25 01:30 London in UTC",
      "2026-10-04 02:15 Australia/Lord_Howe in UTC", "2026-04-05 01:45 Australia/Lord_Howe in UTC",
      "2011-12-30 12:00 Pacific/Apia in UTC", "2026-02-29 18:00 Moscow in London",
      "2026-04-31 18:00 Moscow in London", "1899-12-31 18:00 Moscow in London",
      "24:00 Moscow in London", "18:60 Moscow in London", "18:00 CST in London",
      "18:00 Moscow in IST", "18:00 Springfield in London", "18:00 Europe/Nowhere in London",
      "18:00 UTC+15 in London", "18:00 UTC+14:01 in London", "18:00 UTC-05:60 in London",
      "2026-01-15 18:00 Moscow in London 2026-01-16",
    ] {
      XCTAssertEqual(
        Calculator.calculate(query, context: CalculationContext(now: now))?.status, .error, query)
    }
    let overlap = Calculator.calculate("2026-11-01 01:30 New York in UTC")!
    XCTAssertTrue(overlap.message!.contains("UTC−04:00 или UTC−05:00"))
    XCTAssertEqual(
      Calculator.calculate("2026-03-08 01:59 New York in UTC")?.displayValue, "06:59 UTC+00:00")
    XCTAssertEqual(
      Calculator.calculate("2026-03-08 03:00 New York in UTC")?.displayValue, "07:00 UTC+00:00")
    XCTAssertEqual(
      Calculator.calculate(
        "18:00 Moscow in London", context: CalculationContext(now: now, sourceDate: "2026-02-30"))?
        .status, .error)
    XCTAssertEqual(
      Calculator.calculate(
        "18:00 Moscow in London",
        context: CalculationContext(now: Date(timeIntervalSince1970: .nan)))?.status, .error)
  }
}

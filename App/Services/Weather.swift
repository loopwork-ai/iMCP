import CoreLocation
import Foundation
import OSLog
import WeatherKit

private let log = Logger.service("weather")

final class WeatherService: Service {
    static let shared = WeatherService()
    
    private let weatherService = WeatherKit.WeatherService.shared
    
    var tools: [Tool] {
        return [
            getCurrentWeatherTool(),
            getHourlyWeatherForecastTool(),
            getDailyWeatherForecastTool(),
            getMinuteWeatherForecastTool(),
            getHistoricalWeatherForecastTool()
        ]
    }
    
    private func getCurrentWeatherTool() -> Tool {
        Tool(
            name: "getCurrentWeatherForLocation",
            description: "Get current weather for a location",
            inputSchema: [
                "type": "object",
                "properties": [
                    "latitude": [
                        "type": "number",
                        "description": "The latitude of the location",
                    ],
                    "longitude": [
                        "type": "number",
                        "description": "The longitude of the location",
                    ],
                ],
            ]
        ) { arguments -> Value in
            guard case let .double(latitude) = arguments["latitude"],
                  case let .double(longitude) = arguments["longitude"]
            else {
                log.error("Invalid coordinates")
                throw NSError(
                    domain: "WeatherServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                )
            }

            // Create a location from the coordinates
            let location = CLLocation(latitude: latitude, longitude: longitude)

            // Get the weather for the location
            let currentWeather = try await self.weatherService.weather(
                for: location, including: .current)

            // Extract the relevant information
            let temperature = currentWeather.temperature
            let tempC = temperature.converted(to: .celsius).value
            
            let feelsLike = currentWeather.apparentTemperature
            let feelsLikeC = feelsLike.converted(to: .celsius).value

            let windSpeed = currentWeather.wind.speed
            let windSpeedKMH = windSpeed.converted(to: .kilometersPerHour).value
            
            let visibility = currentWeather.visibility
            let visibilityKM = visibility.converted(to: .kilometers).value
            
            let condition = currentWeather.condition.description
            let cloudCover = currentWeather.cloudCover
            let humidity = currentWeather.humidity
            let uvIndex = currentWeather.uvIndex.value
            let pressure = currentWeather.pressure.value
            let pressureTrend = currentWeather.pressureTrend.description

            return [
                "@context": "https://schema.org",
                "@type": "WeatherObservation",
                "observationDate": .string(currentWeather.date.ISO8601Format()),
                "temperature": [
                    "@type": "QuantitativeValue",
                    "value": .double(tempC),
                    "unitCode": "CEL",
                ],
                "feelsLike": [
                    "@type": "QuantitativeValue",
                    "value": .double(feelsLikeC),
                    "unitCode": "CEL",
                ],
                "windSpeed": [
                    "@type": "QuantitativeValue",
                    "value": .double(windSpeedKMH),
                    "unitCode": "KMH",
                ],
                "windDirection": .double(currentWeather.wind.direction.value),
                "visibility": [
                    "@type": "QuantitativeValue",
                    "value": .double(visibilityKM),
                    "unitCode": "KMT"
                ],
                "condition": .string(condition),
                "cloudCover": .double(cloudCover * 100),
                "humidity": .double(humidity * 100),
                "uvIndex": .int(uvIndex),
                "pressure": [
                    "@type": "QuantitativeValue",
                    "value": .double(pressure),
                    "unitCode": "HPA"
                ],
                "pressureTrend": .string(pressureTrend)
            ]
        }
    }
    
    private func getHourlyWeatherForecastTool() -> Tool {
        Tool(
            name: "getHourlyForecastForLocation",
            description: "Get hourly weather forecast for a location",
            inputSchema: [
                "type": "object",
                "properties": [
                    "latitude": [
                        "type": "number",
                        "description": "The latitude of the location",
                    ],
                    "longitude": [
                        "type": "number",
                        "description": "The longitude of the location",
                    ],
                    "hours": [
                        "type": "number",
                        "description": "Number of hours to forecast (default 24, max 240)",
                        "default": 24
                    ]
                ],
            ]
        ) { arguments -> Value in
            guard case let .double(latitude) = arguments["latitude"],
                  case let .double(longitude) = arguments["longitude"]
            else {
                log.error("Invalid coordinates")
                throw NSError(
                    domain: "WeatherServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                )
            }
            
            let hours: Int
            if case let .double(hoursRequested) = arguments["hours"] {
                hours = Int(min(240, max(1, hoursRequested)))
            } else {
                hours = 24
            }

            let location = CLLocation(latitude: latitude, longitude: longitude)
            let hourlyForecast = try await self.weatherService.weather(
                for: location, including: .hourly)
            
            // Limit to requested hours
            let nextHours = hourlyForecast.prefix(hours)
            
            var forecastArray: [Value] = []
            
            for hour in nextHours {
                let temp = hour.temperature
                let tempC = temp.converted(to: .celsius).value
                
                let feelsLike = hour.apparentTemperature
                let feelsLikeC = feelsLike.converted(to: .celsius).value
                
                let windSpeed = hour.wind.speed
                let windSpeedKMH = windSpeed.converted(to: .kilometersPerHour).value
                
                forecastArray.append([
                    "@type": "WeatherForecast",
                    "forecastTime": .string(hour.date.ISO8601Format()),
                    "temperature": [
                        "@type": "QuantitativeValue",
                        "value": .double(tempC),
                        "unitCode": "CEL"
                    ],
                    "feelsLike": [
                        "@type": "QuantitativeValue",
                        "value": .double(feelsLikeC),
                        "unitCode": "CEL"
                    ],
                    "windSpeed": [
                        "@type": "QuantitativeValue",
                        "value": .double(windSpeedKMH),
                        "unitCode": "KMH"
                    ],
                    "windDirection": .double(hour.wind.direction.value),
                    "condition": .string(hour.condition.description),
                    "cloudCover": .double(hour.cloudCover * 100),
                    "humidity": .double(hour.humidity * 100),
                    "precipitationChance": .double(hour.precipitationChance * 100),
                    "uvIndex": .int(hour.uvIndex.value),
                    "pressure": [
                        "@type": "QuantitativeValue",
                        "value": .double(hour.pressure.value),
                        "unitCode": "HPA"
                    ],
                    "pressureTrend": .string(hour.pressureTrend.description)
                ])
            }

            return [
                "@context": "https://schema.org",
                "@type": "WeatherForecasts",
                "forecasts": .array(forecastArray)
            ]
        }
    }
    
    private func getDailyWeatherForecastTool() -> Tool {
        Tool(
            name: "getDailyForecastForLocation",
            description: "Get daily weather forecast for a location",
            inputSchema: [
                "type": "object",
                "properties": [
                    "latitude": [
                        "type": "number",
                        "description": "The latitude of the location",
                    ],
                    "longitude": [
                        "type": "number",
                        "description": "The longitude of the location",
                    ],
                    "days": [
                        "type": "number",
                        "description": "Number of days to forecast (default 7, max 10)",
                        "default": 7
                    ]
                ],
            ]
        ) { arguments -> Value in
            guard case let .double(latitude) = arguments["latitude"],
                  case let .double(longitude) = arguments["longitude"]
            else {
                log.error("Invalid coordinates")
                throw NSError(
                    domain: "WeatherServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                )
            }
            
            let days: Int
            if case let .double(daysRequested) = arguments["days"] {
                days = Int(min(10, max(1, daysRequested)))
            } else {
                days = 7
            }

            let location = CLLocation(latitude: latitude, longitude: longitude)
            let dailyForecast = try await self.weatherService.weather(
                for: location, including: .daily)
            
            // Limit to requested days
            let forecastDays = dailyForecast.prefix(days)
            
            var forecastArray: [Value] = []
            
            for day in forecastDays {
                let highTemp = day.highTemperature
                let highTempC = highTemp.converted(to: .celsius).value
                let highTempF = highTemp.converted(to: .fahrenheit).value
                
                let lowTemp = day.lowTemperature
                let lowTempC = lowTemp.converted(to: .celsius).value
                let lowTempF = lowTemp.converted(to: .fahrenheit).value
                
                var sunriseTime: String? = nil
                if let sunrise = day.sun.sunrise {
                    sunriseTime = sunrise.ISO8601Format()
                }
                
                var sunsetTime: String? = nil
                if let sunset = day.sun.sunset {
                    sunsetTime = sunset.ISO8601Format()
                }
                
                forecastArray.append([
                    "@type": "WeatherForecast",
                    "forecastDate": .string(day.date.ISO8601Format()),
                    "highTemperature": [
                        "@type": "QuantitativeValue",
                        "value": .double(highTempC),
                        "unitCode": "CEL",
                        "valueInFahrenheit": .double(highTempF)
                    ],
                    "lowTemperature": [
                        "@type": "QuantitativeValue",
                        "value": .double(lowTempC),
                        "unitCode": "CEL",
                        "valueInFahrenheit": .double(lowTempF)
                    ],
                    "condition": .string(day.condition.description),
                    "precipitationChance": .double(day.precipitationChance * 100),
                    "uvIndex": .int(day.uvIndex.value),
                    "sunrise": sunriseTime != nil ? .string(sunriseTime!) : .null,
                    "sunset": sunsetTime != nil ? .string(sunsetTime!) : .null
                ])
            }

            return [
                "@context": "https://schema.org",
                "@type": "WeatherForecasts",
                "forecasts": .array(forecastArray)
            ]
        }
    }
    
    private func getMinuteWeatherForecastTool() -> Tool {
        Tool(
            name: "getMinuteByMinuteForecastForLocation",
            description: "Get minute-by-minute precipitation forecast for a location",
            inputSchema: [
                "type": "object",
                "properties": [
                    "latitude": [
                        "type": "number",
                        "description": "The latitude of the location",
                    ],
                    "longitude": [
                        "type": "number",
                        "description": "The longitude of the location",
                    ],
                    "minutes": [
                        "type": "number",
                        "description": "Number of minutes to forecast (default 60)",
                        "default": 60
                    ]
                ],
            ]
        ) { arguments -> Value in
            guard case let .double(latitude) = arguments["latitude"],
                  case let .double(longitude) = arguments["longitude"]
            else {
                log.error("Invalid coordinates")
                throw NSError(
                    domain: "WeatherServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid coordinates"]
                )
            }
            
            let minutes: Int
            if case let .double(minutesRequested) = arguments["minutes"] {
                minutes = Int(min(120, max(1, minutesRequested)))
            } else {
                minutes = 60
            }

            let location = CLLocation(latitude: latitude, longitude: longitude)
            let minuteWeather = try await self.weatherService.weather(
                for: location, including: .minute)
            
            // Minute forecast might be nil in some regions
            guard let minuteForecast = minuteWeather else {
                return [
                    "@context": "https://schema.org",
                    "@type": "Text",
                    "text": .string("Minute-by-minute forecast not available for this location.")
                ]
            }
            
            // Limit to requested minutes
            let nextMinutes = minuteForecast.prefix(minutes)
            
            var forecastArray: [Value] = []
            
            for minute in nextMinutes {
                forecastArray.append([
                    "@type": "WeatherForecast",
                    "forecastTime": .string(minute.date.ISO8601Format()),
                    "precipitationIntensity": [
                        "@type": "QuantitativeValue",
                        "value": .double(minute.precipitationIntensity.value),
                        "unitCode": "MMH"
                    ],
                    "precipitationChance": .double(minute.precipitationChance * 100),
                    "precipitationType": .string(minute.precipitation.description)
                ])
            }

            return [
                "@context": "https://schema.org",
                "@type": "WeatherForecasts",
                "summary": .string(minuteForecast.summary),
                "forecasts": .array(forecastArray)
            ]
        }
    }
    
    private func getHistoricalWeatherForecastTool() -> Tool {
        Tool(
            name: "getHistoricalWeatherForLocation",
            description: "Get historical weather data for a location",
            inputSchema: [
                "type": "object",
                "properties": [
                    "latitude": [
                        "type": "number",
                        "description": "The latitude of the location",
                    ],
                    "longitude": [
                        "type": "number",
                        "description": "The longitude of the location",
                    ],
                    "startDate": [
                        "type": "string",
                        "description": "Start date in ISO 8601 format (YYYY-MM-DD)",
                    ],
                    "endDate": [
                        "type": "string",
                        "description": "End date in ISO 8601 format (YYYY-MM-DD)",
                    ]
                ],
                "required": ["latitude", "longitude", "startDate", "endDate"]
            ]
        ) { arguments -> Value in
            guard case let .double(latitude) = arguments["latitude"],
                  case let .double(longitude) = arguments["longitude"],
                  case let .string(startDateString) = arguments["startDate"],
                  case let .string(endDateString) = arguments["endDate"]
            else {
                log.error("Invalid arguments")
                throw NSError(
                    domain: "WeatherServiceError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid arguments"]
                )
            }
            
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withFullDate]
            
            guard let startDate = dateFormatter.date(from: startDateString),
                  let inputEndDate = dateFormatter.date(from: endDateString)
            else {
                log.error("Invalid date format")
                throw NSError(
                    domain: "WeatherServiceError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid date format. Use ISO 8601 (YYYY-MM-DD)"]
                )
            }
            
            // Check if dates are within range (available from Aug 1, 2021)
            let minDate = Calendar.current.date(from: DateComponents(year: 2021, month: 8, day: 1)) ?? Date.distantPast
            
            if startDate < minDate {
                return [
                    "@context": "https://schema.org",
                    "@type": "Text",
                    "text": .string("Historical data is only available from August 1, 2021 onwards.")
                ]
            }
            
            // Calculate the end date based on range validation
            let calendar = Calendar.current
            let daysBetween = calendar.dateComponents([.day], from: startDate, to: inputEndDate).day ?? 0
            let endDate: Date
            
            if daysBetween > 9 {
                // If requested range is more than 9 days, limit to start date + 9 days
                endDate = calendar.date(byAdding: .day, value: 9, to: startDate) ?? inputEndDate
            } else {
                // Otherwise use the requested end date
                endDate = inputEndDate
            }
            
            let location = CLLocation(latitude: latitude, longitude: longitude)
            
            // Get daily historical data
            let dailyQuery = WeatherQuery.daily(startDate: startDate, endDate: endDate)
            let dailyData = try await self.weatherService.weather(for: location, including: dailyQuery)
            
            if dailyData.isEmpty {
                return [
                    "@context": "https://schema.org",
                    "@type": "Text",
                    "text": .string("No historical data available for the specified period.")
                ]
            }
            
            var historicalArray: [Value] = []
            
            for day in dailyData {
                let highTemp = day.highTemperature
                let highTempC = highTemp.converted(to: .celsius).value
                
                let lowTemp = day.lowTemperature
                let lowTempC = lowTemp.converted(to: .celsius).value
                
                historicalArray.append([
                    "@type": "WeatherForecast",
                    "forecastDate": .string(day.date.ISO8601Format()),
                    "highTemperature": [
                        "@type": "QuantitativeValue",
                        "value": .double(highTempC),
                        "unitCode": "CEL"
                    ],
                    "lowTemperature": [
                        "@type": "QuantitativeValue",
                        "value": .double(lowTempC),
                        "unitCode": "CEL"
                    ],
                    "condition": .string(day.condition.description),
                    "precipitationChance": .double(day.precipitationChance * 100)
                ])
            }
            
            return [
                "@context": "https://schema.org",
                "@type": "WeatherHistoricalData",
                "startDate": .string(startDate.ISO8601Format()),
                "endDate": .string(endDate.ISO8601Format()),
                "historicalData": .array(historicalArray)
            ]
        }
    }
}

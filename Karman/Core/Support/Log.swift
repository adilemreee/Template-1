import os

enum Log {
    static let app = Logger(subsystem: "com.adilemre.karman", category: "app")
    static let render = Logger(subsystem: "com.adilemre.karman", category: "render")
}

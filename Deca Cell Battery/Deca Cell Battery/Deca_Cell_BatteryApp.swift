//
//  Deca_Cell_BatteryApp.swift
//  Deca Cell Battery
//
//  Created by David Nishimoto on 10/6/26.
//

import SwiftUI
import CoreData

@main
struct Deca_Cell_BatteryApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

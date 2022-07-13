/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import os.activity
import OpenTelemetryApi

// Bridging Obj-C variabled defined as c-macroses. See `activity.h` header.
private let OS_ACTIVITY_CURRENT = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_os_activity_current"),
                                                to: os_activity_t.self)
@_silgen_name("_os_activity_create") private func _os_activity_create(_ dso: UnsafeRawPointer?,
                                                                      _ description: UnsafePointer<Int8>,
                                                                      _ parent: Unmanaged<AnyObject>?,
                                                                      _ flags: os_activity_flag_t) -> AnyObject!

class ActivityContextManager: ContextManager {
    static let instance = ActivityContextManager()
    
    
    let rlock = NSRecursiveLock()

    class ScopeElement {
        init(scope: os_activity_scope_state_s) {
            self.scope = scope
        }

        var scope: os_activity_scope_state_s
    }

    var objectScope = NSMapTable<AnyObject, ScopeElement>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    var contextMap = [os_activity_id_t: [String: Stack]]()

    func getCurrentContextValue(forKey key: OpenTelemetryContextKeys) -> AnyObject? {
        var parentIdent: os_activity_id_t = 0
        let activityIdent = os_activity_get_identifier(OS_ACTIVITY_CURRENT, &parentIdent)
        var contextValue: AnyObject?
        rlock.lock()
        guard let context = contextMap[activityIdent] ?? contextMap[parentIdent] else {
            rlock.unlock()
            return nil
        }
        contextValue = context[key.rawValue]?.peek()
        rlock.unlock()
        return contextValue
    }

    func setCurrentContextValue(forKey key: OpenTelemetryContextKeys, value: AnyObject) {
        var parentIdent: os_activity_id_t = 0
        var activityIdent = os_activity_get_identifier(OS_ACTIVITY_CURRENT, &parentIdent)
        rlock.lock()
        if(activityIdent != 0 && (value as! RecordEventsReadableSpan).parentContext == nil){
            var activityState = os_activity_scope_state_s()
            activityState.opaque.0 = activityIdent
            os_activity_scope_leave(&activityState)
            let afterIdent = os_activity_get_identifier(OS_ACTIVITY_CURRENT, &parentIdent)
            
            print("#### afterIdent: \(afterIdent)")
        }
        if contextMap[activityIdent] == nil || contextMap[activityIdent]?[key.rawValue] != nil {
            var scope: os_activity_scope_state_s
            if((value as! RecordEventsReadableSpan).parentContext == nil){
                (activityIdent, scope) = createActivityContext()
                objectScope.setObject(ScopeElement(scope: scope), forKey: value)
            }
            contextMap[activityIdent] = [String: Stack]()
        }
        contextMap[activityIdent]?[key.rawValue]?.push(value)
        let context = contextMap[activityIdent]
        let v = contextMap[activityIdent]?[key.rawValue]?.peek()
        rlock.unlock()
    }

    func createActivityContext() -> (os_activity_id_t, os_activity_scope_state_s) {
        let dso = UnsafeMutableRawPointer(mutating: #dsohandle)
        let currentBefore = os_activity_get_identifier(OS_ACTIVITY_CURRENT, nil)
        let activity = _os_activity_create(dso, "ActivityContext", OS_ACTIVITY_CURRENT, OS_ACTIVITY_FLAG_DEFAULT)
        let currentActivityId = os_activity_get_identifier(activity, nil)
        var activityState = os_activity_scope_state_s()
        os_activity_scope_enter(activity, &activityState)
        return (currentActivityId, activityState)
    }

    func removeContextValue(forKey key: OpenTelemetryContextKeys, value: AnyObject) {
        var parentIdent: os_activity_id_t = 0
        
        if let scope = objectScope.object(forKey: value) {
            var scope = scope.scope
            let activityIdent = scope.opaque.0
            
            if((value as! RecordEventsReadableSpan).parentContext == nil){
                contextMap.removeValue(forKey: activityIdent)
                os_activity_scope_leave(&scope)
            } else if(contextMap[activityIdent] != nil && contextMap[activityIdent]?[key.rawValue] != nil) {
                let currentContext = contextMap[activityIdent]?[key.rawValue]?.peek()
                if((currentContext as! Span).context.spanId == (value as! Span).context.spanId){
                    contextMap[activityIdent]?[key.rawValue]?.pop()
                }
            }
            
            objectScope.removeObject(forKey: value)
        }
    }
}

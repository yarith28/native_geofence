import Foundation

/// Process-stable owner of every object that can admit or resolve a Core
/// Location mutation. Flutter engine detach only replaces event delivery; it
/// must not replace pending registrations, rollback tombstones, preflight
/// tokens, or the queue that grants synchronization exclusivity.
final class IosGeofenceMutationAuthority {
    typealias EventDelivery = (
        GeofenceCallbackParamsWire,
        @escaping (Bool) -> Void
    ) -> Void
    typealias DeliveryAttachment = IosReattachableDelivery<EventDelivery>.Attachment

    static let shared = IosGeofenceMutationAuthority()

    private let eventDelivery = IosReattachableDelivery<EventDelivery>()

    private(set) lazy var locationManagerDelegate = LocationManagerDelegate(
        deliverEvent: { [weak self] params, completion in
            guard let self,
                  eventDelivery.withCurrent({ delivery in
                      delivery(params, completion)
                  }) != nil
            else {
                completion(false)
                return
            }
        }
    )
    private(set) lazy var nativeApi = NativeGeofenceApiImpl(
        locationManagerDelegate: locationManagerDelegate
    )

    private init() {}

    func attachEventDelivery(_ delivery: @escaping EventDelivery) -> DeliveryAttachment {
        let attachment = eventDelivery.attach(delivery)
        locationManagerDelegate.drainPendingEvents()
        return attachment
    }

    func detachEventDelivery(_ attachment: DeliveryAttachment) {
        eventDelivery.detach(attachment)
    }
}

/// A dispatcher could not resolve a persisted downstream callback.
/// Throw only before invoking application work, never for application failures.
class CallbackRegistrationUnavailable implements Exception {
  const CallbackRegistrationUnavailable();
}

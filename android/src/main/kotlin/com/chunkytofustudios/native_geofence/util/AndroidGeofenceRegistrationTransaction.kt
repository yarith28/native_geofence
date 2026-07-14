package com.chunkytofustudios.native_geofence.util

internal fun interface AndroidGeofenceAsyncOperation {
    /** Attaches exactly one success and failure route. Implementations may throw. */
    fun attach(onSuccess: () -> Unit, onFailure: (Throwable) -> Unit)
}

internal enum class AndroidGeofenceRegistrationFailureStage {
    PROVISIONAL_PERSISTENCE,
    PLATFORM_INVOCATION,
    PLATFORM_LISTENER_REGISTRATION,
    PLATFORM_REGISTRATION,
    ACTIVE_STATE_PERSISTENCE
}

internal enum class AndroidGeofenceTransactionStepOutcome {
    NOT_ATTEMPTED,
    SUCCEEDED,
    FAILED
}

internal class AndroidGeofenceRegistrationTransactionException(
    val stage: AndroidGeofenceRegistrationFailureStage,
    val primaryCause: Throwable?,
    val compensation: AndroidGeofenceTransactionStepOutcome,
    val durableRestoration: AndroidGeofenceTransactionStepOutcome,
    val previousPlatformRestoration: AndroidGeofenceTransactionStepOutcome,
    val evidencePersistence: AndroidGeofenceTransactionStepOutcome,
    val compensationCause: Throwable? = null,
    val previousPlatformRestorationCause: Throwable? = null,
) : RuntimeException(
    buildString {
        append("Android geofence registration transaction failed at ")
        append(stage.name.lowercase())
        append(" (compensation=")
        append(compensation.name.lowercase())
        append(", durableRestoration=")
        append(durableRestoration.name.lowercase())
        append(", previousPlatformRestoration=")
        append(previousPlatformRestoration.name.lowercase())
        append(", evidencePersistence=")
        append(evidencePersistence.name.lowercase())
        append(").")
    },
    primaryCause,
) {
    fun privacySafeDetails(): String = buildString {
        append("stage=")
        append(stage.name.lowercase())
        append(", compensation=")
        append(compensation.name.lowercase())
        append(", durableRestoration=")
        append(durableRestoration.name.lowercase())
        append(", previousPlatformRestoration=")
        append(previousPlatformRestoration.name.lowercase())
        append(", evidencePersistence=")
        append(evidencePersistence.name.lowercase())
        appendCause("primary", primaryCause)
        appendCause("compensation", compensationCause)
        appendCause("previousPlatformRestoration", previousPlatformRestorationCause)
    }.take(2_000)

    private fun StringBuilder.appendCause(label: String, throwable: Throwable?) {
        if (throwable == null) return
        append(", ")
        append(label)
        append("Cause=")
        append(throwable.javaClass.simpleName)
    }
}

/**
 * Coordinates one Android registration as a transaction across Play services
 * and the complete durable registration snapshot.
 *
 * Each asynchronous callback is accepted only while its owning stage is
 * current. This makes synchronous listener-wiring failures and late Task
 * callbacks safe without depending on the later public mutation queue.
 */
internal class AndroidGeofenceRegistrationTransaction(
    private val previousRegistrationExists: Boolean,
    private val previousPlatformRestorationRequired: Boolean,
    private val saveProvisional: () -> Boolean,
    private val markActive: () -> Boolean,
    private val restoreDurableSnapshot: () -> Boolean,
    private val preserveInactiveEvidence: () -> Boolean,
    private val beginCurrentRegistration: () -> AndroidGeofenceAsyncOperation,
    private val beginCompensation: () -> AndroidGeofenceAsyncOperation,
    private val beginPreviousPlatformRestoration: () -> AndroidGeofenceAsyncOperation,
    private val completion: (Result<Unit>) -> Unit,
) {
    private enum class State {
        IDLE,
        REGISTERING,
        COMMITTING,
        COMPENSATING,
        RESTORING_DURABLE,
        RESTORING_PLATFORM,
        FINALIZING,
        FINISHED
    }

    private data class FailureState(
        val stage: AndroidGeofenceRegistrationFailureStage,
        val primaryCause: Throwable?,
        val compensation: AndroidGeofenceTransactionStepOutcome =
            AndroidGeofenceTransactionStepOutcome.NOT_ATTEMPTED,
        val durableRestoration: AndroidGeofenceTransactionStepOutcome =
            AndroidGeofenceTransactionStepOutcome.NOT_ATTEMPTED,
        val previousPlatformRestoration: AndroidGeofenceTransactionStepOutcome =
            AndroidGeofenceTransactionStepOutcome.NOT_ATTEMPTED,
        val evidencePersistence: AndroidGeofenceTransactionStepOutcome =
            AndroidGeofenceTransactionStepOutcome.NOT_ATTEMPTED,
        val compensationCause: Throwable? = null,
        val previousPlatformRestorationCause: Throwable? = null,
    )

    private val lock = Any()
    private var state = State.IDLE

    fun start() {
        if (!transition(State.IDLE, State.REGISTERING)) return

        val provisionalSaved = try {
            saveProvisional()
        } catch (error: Throwable) {
            rollbackWithoutCompensation(
                FailureState(
                    AndroidGeofenceRegistrationFailureStage.PROVISIONAL_PERSISTENCE,
                    error,
                ),
                State.REGISTERING,
            )
            return
        }
        if (!provisionalSaved) {
            rollbackWithoutCompensation(
                FailureState(
                    AndroidGeofenceRegistrationFailureStage.PROVISIONAL_PERSISTENCE,
                    null,
                ),
                State.REGISTERING,
            )
            return
        }

        val operation = try {
            beginCurrentRegistration()
        } catch (error: Throwable) {
            rollbackWithoutCompensation(
                FailureState(
                    AndroidGeofenceRegistrationFailureStage.PLATFORM_INVOCATION,
                    error,
                ),
                State.REGISTERING,
            )
            return
        }

        try {
            operation.attach(::currentRegistrationSucceeded, ::currentRegistrationFailed)
        } catch (error: Throwable) {
            startCompensation(
                FailureState(
                    AndroidGeofenceRegistrationFailureStage.PLATFORM_LISTENER_REGISTRATION,
                    error,
                ),
                State.REGISTERING,
            )
        }
    }

    private fun currentRegistrationSucceeded() {
        if (!transition(State.REGISTERING, State.COMMITTING)) return
        val activeCommitted = try {
            markActive()
        } catch (error: Throwable) {
            startCompensation(
                FailureState(
                    AndroidGeofenceRegistrationFailureStage.ACTIVE_STATE_PERSISTENCE,
                    error,
                ),
                State.COMMITTING,
            )
            return
        }
        if (!activeCommitted) {
            startCompensation(
                FailureState(
                    AndroidGeofenceRegistrationFailureStage.ACTIVE_STATE_PERSISTENCE,
                    null,
                ),
                State.COMMITTING,
            )
            return
        }
        finishSuccess(State.COMMITTING)
    }

    private fun currentRegistrationFailed(error: Throwable) {
        val failure = FailureState(
            AndroidGeofenceRegistrationFailureStage.PLATFORM_REGISTRATION,
            error,
        )
        if (error is AndroidGeofenceMutationTimeoutException) {
            // The Task outcome is unknown. Remove the requested ID before
            // restoring durable and previous-platform authority.
            startCompensation(failure, State.REGISTERING)
        } else {
            rollbackWithoutCompensation(failure, State.REGISTERING)
        }
    }

    private fun rollbackWithoutCompensation(failure: FailureState, expectedState: State) {
        if (!transition(expectedState, State.RESTORING_DURABLE)) return
        val restored = safeBoolean(restoreDurableSnapshot)
        finishFailure(
            failure.copy(
                durableRestoration = restored.toOutcome(),
            ),
            State.RESTORING_DURABLE,
        )
    }

    private fun startCompensation(failure: FailureState, expectedState: State) {
        if (!transition(expectedState, State.COMPENSATING)) return
        val operation = try {
            beginCompensation()
        } catch (error: Throwable) {
            restoreAfterCompensation(
                failure.copy(
                    compensation = AndroidGeofenceTransactionStepOutcome.FAILED,
                    compensationCause = error,
                ),
                compensationSucceeded = false,
            )
            return
        }

        try {
            operation.attach(
                onSuccess = {
                    restoreAfterCompensation(
                        failure.copy(
                            compensation = AndroidGeofenceTransactionStepOutcome.SUCCEEDED,
                        ),
                        compensationSucceeded = true,
                    )
                },
                onFailure = { error ->
                    restoreAfterCompensation(
                        failure.copy(
                            compensation = AndroidGeofenceTransactionStepOutcome.FAILED,
                            compensationCause = error,
                        ),
                        compensationSucceeded = false,
                    )
                },
            )
        } catch (error: Throwable) {
            restoreAfterCompensation(
                failure.copy(
                    compensation = AndroidGeofenceTransactionStepOutcome.FAILED,
                    compensationCause = error,
                ),
                compensationSucceeded = false,
            )
        }
    }

    private fun restoreAfterCompensation(
        failure: FailureState,
        compensationSucceeded: Boolean,
    ) {
        if (!transition(State.COMPENSATING, State.RESTORING_DURABLE)) return

        if (!compensationSucceeded && !previousRegistrationExists) {
            // The new platform fence may still be live. Keep its provisional raw
            // ID and canonical configuration until later repair or cleanup.
            val evidencePreserved = safeBoolean(preserveInactiveEvidence)
            finishFailure(
                failure.copy(evidencePersistence = evidencePreserved.toOutcome()),
                State.RESTORING_DURABLE,
            )
            return
        }

        val durableRestored = safeBoolean(restoreDurableSnapshot)
        var updatedFailure = failure.copy(
            durableRestoration = durableRestored.toOutcome(),
        )
        if (!durableRestored) {
            // The atomic failed restore leaves the provisional record in place.
            val evidencePreserved = safeBoolean(preserveInactiveEvidence)
            finishFailure(
                updatedFailure.copy(evidencePersistence = evidencePreserved.toOutcome()),
                State.RESTORING_DURABLE,
            )
            return
        }

        if (!compensationSucceeded) {
            val evidencePreserved = safeBoolean(preserveInactiveEvidence)
            finishFailure(
                updatedFailure.copy(evidencePersistence = evidencePreserved.toOutcome()),
                State.RESTORING_DURABLE,
            )
            return
        }

        if (!previousPlatformRestorationRequired) {
            finishFailure(updatedFailure, State.RESTORING_DURABLE)
            return
        }

        if (!transition(State.RESTORING_DURABLE, State.RESTORING_PLATFORM)) return
        val operation = try {
            beginPreviousPlatformRestoration()
        } catch (error: Throwable) {
            previousPlatformRestorationFailed(updatedFailure, error)
            return
        }
        try {
            operation.attach(
                onSuccess = {
                    if (!transition(State.RESTORING_PLATFORM, State.FINALIZING)) return@attach
                    // Reapply every previous byte after platform restoration so
                    // callback routing, deadlines and lifecycle flags remain exact.
                    val reapplied = safeBoolean(restoreDurableSnapshot)
                    finishFailure(
                        updatedFailure.copy(
                            previousPlatformRestoration =
                                AndroidGeofenceTransactionStepOutcome.SUCCEEDED,
                            durableRestoration = reapplied.toOutcome(),
                        ),
                        State.FINALIZING,
                    )
                },
                onFailure = { error ->
                    previousPlatformRestorationFailed(updatedFailure, error)
                },
            )
        } catch (error: Throwable) {
            previousPlatformRestorationFailed(updatedFailure, error)
        }
    }

    private fun previousPlatformRestorationFailed(
        failure: FailureState,
        error: Throwable,
    ) {
        if (!transition(State.RESTORING_PLATFORM, State.FINALIZING)) return
        val evidencePreserved = safeBoolean(preserveInactiveEvidence)
        finishFailure(
            failure.copy(
                previousPlatformRestoration = AndroidGeofenceTransactionStepOutcome.FAILED,
                evidencePersistence = evidencePreserved.toOutcome(),
                previousPlatformRestorationCause = error,
            ),
            State.FINALIZING,
        )
    }

    private fun finishSuccess(expectedState: State) {
        if (!transition(expectedState, State.FINISHED)) return
        completion(Result.success(Unit))
    }

    private fun finishFailure(failure: FailureState, expectedState: State) {
        if (!transition(expectedState, State.FINISHED)) return
        completion(
            Result.failure(
                AndroidGeofenceRegistrationTransactionException(
                    stage = failure.stage,
                    primaryCause = failure.primaryCause,
                    compensation = failure.compensation,
                    durableRestoration = failure.durableRestoration,
                    previousPlatformRestoration = failure.previousPlatformRestoration,
                    evidencePersistence = failure.evidencePersistence,
                    compensationCause = failure.compensationCause,
                    previousPlatformRestorationCause =
                        failure.previousPlatformRestorationCause,
                ),
            ),
        )
    }

    private fun transition(expected: State, next: State): Boolean = synchronized(lock) {
        if (state != expected) return@synchronized false
        state = next
        true
    }

    private fun safeBoolean(operation: () -> Boolean): Boolean = try {
        operation()
    } catch (_: Throwable) {
        false
    }

    private fun Boolean.toOutcome(): AndroidGeofenceTransactionStepOutcome =
        if (this) {
            AndroidGeofenceTransactionStepOutcome.SUCCEEDED
        } else {
            AndroidGeofenceTransactionStepOutcome.FAILED
        }
}

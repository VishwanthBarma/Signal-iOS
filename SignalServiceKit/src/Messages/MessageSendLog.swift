//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import SignalClient
import GRDB

@objc
public class MessageSendLog: NSObject {

    private static let payloadLifetime = -kDayInterval
    private static var payloadExpirationDate: Date {
        Date(timeIntervalSinceNow: payloadLifetime)
    }

    @objc
    class Payload: NSObject, Codable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "MessageSendLog_Payload"
        static let recipient = hasMany(Recipient.self)

        var payloadId: Int64?
        @objc
        let plaintextContent: Data
        let contentHint: SealedSenderContentHint
        @objc
        let sentTimestamp: Date
        @objc
        let uniqueThreadId: String
        // Indicates whether or not this payload is in the process of being sent.
        // Used to prevent deletion of the MSL entry if a recipient acks delivery
        // before we've finished sending to another recipient.
        var sendComplete: Bool

        init(
            plaintextContent: Data,
            contentHint: SealedSenderContentHint,
            sentTimestamp: Date,
            uniqueThreadId: String,
            sendComplete: Bool
        ) {
            self.plaintextContent = plaintextContent
            self.contentHint = contentHint
            self.sentTimestamp = sentTimestamp
            self.uniqueThreadId = uniqueThreadId
            self.sendComplete = sendComplete
        }

        func didInsert(with rowID: Int64, for column: String?) {
            guard column == "payloadId" else { return owsFailDebug("Expected payloadId") }
            payloadId = rowID
        }
    }

    struct Recipient: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "MessageSendLog_Recipient"
        static let payload = belongsTo(Payload.self)

        private let payloadId: Int64
        private let recipientUUID: UUID
        private let recipientDeviceId: Int64

        init(payloadId: Int64, recipientUUID: UUID, recipientDeviceId: Int64) {
            self.payloadId = payloadId
            self.recipientUUID = recipientUUID
            self.recipientDeviceId = recipientDeviceId
        }
    }

    struct Message: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "MessageSendLog_Message"
        static let payloadId = belongsTo(Payload.self)

        private let payloadId: Int64
        private let uniqueId: String

        init(payloadId: Int64, uniqueId: String) {
            self.payloadId = payloadId
            self.uniqueId = uniqueId
        }
    }

    @objc
    public static func recordPayload(
        _ plaintext: Data,
        forMessageBeingSent message: TSOutgoingMessage,
        transaction writeTx: SDSAnyWriteTransaction
    ) -> NSNumber? {

        guard !RemoteConfig.messageResendKillSwitch else {
            Logger.info("Resend kill switch activated. Ignoring MSL payload save.")
            return nil
        }
        guard message.shouldRecordSendLog else { return nil }

        let payloads: [Payload]
        do {
            payloads = try Payload
                .filter(Column("sentTimestamp") == message.timestampDate())
                .filter(Column("uniqueThreadId") == message.uniqueThreadId)
                .fetchAll(writeTx.unwrapGrdbRead.database)
        } catch {
            owsFailDebug("")
            return nil
        }

        if let existingPayload = payloads.first {
            // We found an existing payload. This message was probably a partial failure the first time
            // Double check the plaintext matches. If it does, we can use the existing payloadId
            // If not, we can't record MSL entries for subsequent sends because the timestamp
            // and threadId will alias each other.
            if payloads.count == 1, existingPayload.plaintextContent == plaintext, let payloadId = existingPayload.payloadId {
                Logger.info("Reusing existing payloadId from a previous send: \(payloadId)")

                // If we're working to record a payload, this message is no longer complete
                // We set "sendComplete" false to make sure if a delivery receipt comes in
                // before we finish sending to the remaining recipients that we don't clear
                // out our payload.
                do {
                    existingPayload.sendComplete = false
                    try existingPayload.update(writeTx.unwrapGrdbWrite.database)
                } catch {
                    owsFailDebug("Failed to mark existing payload incomplete.")
                }

                return NSNumber(value: payloadId)
            } else {
                owsAssertDebug(payloads.count == 1)
                owsAssertDebug(existingPayload.plaintextContent == plaintext)
                owsAssertDebug(existingPayload.payloadId != nil)
                owsFailDebug("MSL payload table inconsistency")
                return nil
            }
        } else {
            // No existing payload found. Create a new one and insert it
            var payload = Payload(
                plaintextContent: plaintext,
                contentHint: message.contentHint,
                sentTimestamp: message.timestampDate(),
                uniqueThreadId: message.uniqueThreadId,
                sendComplete: false)
            do {
                try payload.insert(writeTx.unwrapGrdbWrite.database)
                Logger.info("Inserted MSL payload with id: \(String(describing: payload.payloadId))")

                // If the payload was successfully recorded, we should also record
                // any interactions related to this payload. This should not fail.
                guard let payloadId = payload.payloadId else {
                    throw OWSAssertionError("Expected payloadId to be set")
                }
                try message.relatedUniqueIds.forEach { uniqueId in
                    try Message(payloadId: payloadId, uniqueId: uniqueId)
                        .insert(writeTx.unwrapGrdbWrite.database)
                }
                return NSNumber(value: payloadId)
            } catch {
                owsFailDebug("Unexpected MSL payload insertion error \(error)")
                return nil
            }
        }
    }

    @objc
    static func fetchPayload(
        address: SignalServiceAddress,
        deviceId: Int64,
        timestamp: Date,
        transaction readTx: SDSAnyReadTransaction
    ) -> Payload? {

        guard !RemoteConfig.messageResendKillSwitch else {
            Logger.info("Resend kill switch activated. Ignoring MSL lookup.")
            return nil
        }

        guard timestamp.isAfter(payloadExpirationDate) else {
            Logger.info("Ignoring payload lookup for timestamp before expiration")
            return nil
        }

        do {
            let recipientAlias = TableAlias()
            let request = Payload
                .joining(required: Payload.recipient.aliased(recipientAlias))
                .filter(Column("sentTimestamp") == timestamp)
                .filter(recipientAlias[Column("recipientUUID")] == address.uuid)
                .filter(recipientAlias[Column("recipientDeviceId")] == deviceId)

            let payloads = try Payload.fetchAll(readTx.unwrapGrdbRead.database, request)
            if payloads.count == 1, let result = payloads.first {
                return result
            } else {
                return nil
            }
        } catch {
            owsFailDebug("\(error)")
            return nil
        }
    }

    @objc
    public static func sendComplete(message: TSOutgoingMessage, transaction writeTx: SDSAnyWriteTransaction) {
        guard !RemoteConfig.messageResendKillSwitch else {
            Logger.info("Resend kill switch activated. Ignoring MSL payload save.")
            return
        }
        guard message.shouldRecordSendLog else { return }

        let payloads: [Payload]
        do {
            payloads = try Payload
                .filter(Column("sentTimestamp") == message.timestampDate())
                .filter(Column("uniqueThreadId") == message.uniqueThreadId)
                .fetchAll(writeTx.unwrapGrdbRead.database)

            guard let payload = payloads.first else { return }
            guard payloads.count <= 1 else {
                throw OWSAssertionError("Aliased entries: \(payloads.count)")
            }

            // We found the payload that needs to be marked complete!
            // - If there are any outstanding deliveries, the payload needs to be kept while
            //   we wait for delivery receipts from our recipients.
            // - If every recipient has acked already (this would be an unlikely race) we should
            //   delete the payload now. Our trigger to prune on updates to the recipient table
            //   won't catch this.
            let hasPendingDeliveries = try Recipient
                .filter(Column("payloadId") == payload.payloadId)
                .fetchCount(writeTx.unwrapGrdbWrite.database) > 0

            if hasPendingDeliveries {
                payload.sendComplete = true
                try payload.update(writeTx.unwrapGrdbWrite.database)
            } else {
                try payload.delete(writeTx.unwrapGrdbWrite.database)
            }
        } catch {
            owsFailDebug("Failed to mark send complete for \(message.timestamp): \(error)")
        }
    }

    public static func recordPendingDelivery(
        payloadId: Int64,
        recipientUuid: UUID,
        recipientDeviceId: Int64,
        transaction writeTx: SDSAnyWriteTransaction
    ) {
        guard !RemoteConfig.messageResendKillSwitch else {
            Logger.info("Resend kill switch activated. Ignoring MSL recipient save.")
            return
        }
        do {
            try Recipient(
                payloadId: payloadId,
                recipientUUID: recipientUuid,
                recipientDeviceId: recipientDeviceId
            ).insert(writeTx.unwrapGrdbWrite.database)
        } catch {
            owsFailDebug("Failed to record pending delivery \(error)")
        }
    }

    @objc
    public static func recordSuccessfulDelivery(
        timestamp: Date,
        recipientUuid: UUID,
        recipientDeviceId: Int64,
        transaction writeTx: SDSAnyWriteTransaction
    ) {
        guard !RemoteConfig.messageResendKillSwitch else {
            Logger.info("Resend kill switch activated. Ignoring MSL recipient save.")
            return
        }
        do {
            let payloadAlias = TableAlias()
            let targets: [Recipient] = try Recipient
                .joining(required: Recipient.payload.aliased(payloadAlias))
                .filter(payloadAlias[Column("sentTimestamp")] == timestamp)
                .filter(Column("recipientUuid") == recipientUuid)
                .filter(Column("recipientDeviceId") == recipientDeviceId)
                .fetchAll(writeTx.unwrapGrdbWrite.database)
            try targets.forEach { try $0.delete(writeTx.unwrapGrdbWrite.database) }

        } catch {
            owsFailDebug("Failed to record successful delivery \(error)")
        }
    }

    @objc
    public static func deleteAllPayloadsForInteraction(
        _ interaction: TSInteraction,
        transaction writeTx: SDSAnyWriteTransaction
    ) {
        Logger.info("Deleting all MSL payload entries related to \(interaction.uniqueId)")
        do {
            try Message
                .filter(Column("uniqueId") == interaction.uniqueId)
                .deleteAll(writeTx.unwrapGrdbWrite.database)
        } catch {
            owsFailDebug("Failed to delete payloads for interaction(\(interaction.uniqueId)): \(error)")
        }
    }

    public static func schedulePeriodicCleanup() {
        guard CurrentAppContext().isMainApp, !CurrentAppContext().isRunningTests else { return }

        AppReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            performPeriodicCleanup()
        }
    }

    private static func performPeriodicCleanup() {
        DispatchQueue.sharedBackground.async {
            databaseStorage.write { writeTx in
                forceCleanupStaleEntries(transaction: writeTx)
            }
        }

        DispatchQueue.sharedBackground.asyncAfter(deadline: .now() + kDayInterval) {
            performPeriodicCleanup()
        }
    }

    private static func forceCleanupStaleEntries(transaction: SDSAnyWriteTransaction) {
        do {
            try Payload
                .filter(Column("sentTimestamp") < payloadExpirationDate)
                .deleteAll(transaction.unwrapGrdbWrite.database)
            Logger.info("Trimmed stale entries of MSL")
        } catch {
            owsFailDebug("Failed to trim stale MSL entries: \(error)")
        }
    }

    #if TESTABLE_BUILD
    static func test_forceCleanupStaleEntries(transaction: SDSAnyWriteTransaction) {
        forceCleanupStaleEntries(transaction: transaction)
    }
    #endif
}

extension SealedSenderContentHint: Codable {}

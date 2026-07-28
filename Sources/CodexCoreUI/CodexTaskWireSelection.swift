import CodexCore

package struct CodexTaskWireSelection: Equatable, Sendable {
    package var modelIdentifier: String?
    package var serviceTier: String?
    package var effort: CodexSchemaReasoningEffort?

    package init(
        modelIdentifier: String?,
        serviceTier: String?,
        effort: CodexSchemaReasoningEffort?
    ) {
        self.modelIdentifier = modelIdentifier
        self.serviceTier = serviceTier
        self.effort = effort
    }

    package func omittingEffort() -> Self {
        Self(
            modelIdentifier: modelIdentifier,
            serviceTier: serviceTier,
            effort: nil
        )
    }

    package func omittingModelSpecificOverrides() -> Self {
        Self(
            modelIdentifier: modelIdentifier,
            serviceTier: nil,
            effort: nil
        )
    }

    package func overriding(
        model requestedModel: String?,
        effort requestedEffort: String?
    ) -> Self {
        let changesModel = requestedModel != nil
            && requestedModel != modelIdentifier
        return Self(
            modelIdentifier: requestedModel ?? modelIdentifier,
            serviceTier: changesModel ? nil : serviceTier,
            effort: requestedEffort.map {
                CodexSchemaReasoningEffort(.string($0))
            } ?? (changesModel ? nil : effort)
        )
    }

    package func applying(
        to parameters: CodexSchemaThreadStartParams
    ) -> CodexSchemaThreadStartParams {
        var result = parameters
        result.model = modelIdentifier
        result.serviceTier = serviceTier
        return result
    }

    package func applying(
        to parameters: CodexSchemaThreadResumeParams
    ) -> CodexSchemaThreadResumeParams {
        var result = parameters
        result.model = modelIdentifier
        result.serviceTier = serviceTier
        return result
    }

    package func applying(
        to parameters: CodexSchemaThreadForkParams
    ) -> CodexSchemaThreadForkParams {
        var result = parameters
        result.model = modelIdentifier
        result.serviceTier = serviceTier
        return result
    }

    package func applying(
        to parameters: CodexSchemaTurnStartParams
    ) -> CodexSchemaTurnStartParams {
        var result = parameters
        result.model = modelIdentifier
        result.serviceTier = serviceTier
        result.effort = effort
        return result
    }
}

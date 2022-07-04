module infoflow.test.test_models;

import infoflow.models;

import infoflow.test.test_common;

@("models.basic")
unittest {
    auto commits = [
        Commit().with_pc(0)
            .with_type(InfoType.Register)
            .with_effects([
                InfoNode(InfoType.Register, TinyRegisters.R0, 0xa)
            ])
            .with_sources([
                InfoNode(InfoType.Immediate, 0, 0xa)
            ])
            .with_description("set R0 0xa")
    ];
}
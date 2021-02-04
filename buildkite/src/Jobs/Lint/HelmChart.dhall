let Prelude = ../../External/Prelude.dhall
let B = ../../External/Buildkite.dhall

let B/SoftFail = B.definitions/commandStep/properties/soft_fail/Type

let S = ../../Lib/SelectFiles.dhall
let Cmd = ../../Lib/Cmds.dhall

let Pipeline = ../../Pipeline/Dsl.dhall
let JobSpec = ../../Pipeline/JobSpec.dhall

let Command = ../../Command/Base.dhall
let Docker = ../../Command/Docker/Type.dhall
let Size = ../../Command/Size.dhall

let jobDocker = Cmd.Docker::{image = (../../Constants/ContainerImages.dhall).codaToolchain}

in

Pipeline.build
  Pipeline.Config::{
    spec = JobSpec::{
      dirtyWhen = [
        S.contains "helm/",
        S.strictlyStart (S.contains "buildkite/src/Jobs/Lint/HelmChart"),
        -- trigger on HelmRelease job change due to dependency
        S.strictlyStart (S.contains "buildkite/src/Jobs/Release/HelmRelease"),
        S.exactly "buildkite/scripts/helm-ci" "sh"
      ],
      path = "Lint",
      name = "HelmChart"
    },
    steps = [
      Command.build
        Command.Config::{
          commands = [ Cmd.run "HELM_LINT=true buildkite/scripts/helm-ci.sh" ]
          , label = "Helm chart lint steps"
          , key = "lint-helm-chart"
          , target = Size.Small
          , docker = None Docker.Type
        }
    ]
  }

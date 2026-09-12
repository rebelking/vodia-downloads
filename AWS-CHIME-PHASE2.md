# Amazon Chime SDK Voice — Phase 2

Phase 2 extends the Vodia MCP Amazon Chime integration with deeper read-only Voice Connector inspection and a guarded create workflow.

## New read tools

- `aws_chime_get_termination`
- `aws_chime_get_origination`
- `aws_chime_list_termination_credentials`
- `aws_chime_get_termination_health`
- `aws_chime_list_available_regions`
- `aws_chime_recommend_region`

## Guarded write workflow

- `aws_chime_plan_create_voice_connector`
- `aws_chime_apply_change`

Creating a Voice Connector is a two-step action. The planner returns a short-lived change ID and an exact confirmation string. The apply tool rejects expired, reused, mismatched-actor, or incorrectly confirmed plans.

Phase 2 intentionally creates only the top-level Amazon Chime SDK Voice Connector. Termination/origination writes, SIP credential creation, phone-number association, and Vodia PBX trunk creation remain deferred until this phase is validated.

## IAM

The included `aws-chime-phase2-policy.json` adds only the Chime SDK Voice permissions required by the Phase 2 reads and `CreateVoiceConnector`. The connector continues to use the AWS SDK default credential provider chain, so EC2 instance-role credentials are preferred over static keys.

## Install

Extract `vodia-mcp-aws-chime-phase2.zip`, review the files, then run:

```bash
sudo bash apply-aws-chime-phase2.sh
```

After installing, update the EC2 role inline policy with the included Phase 2 policy and restart `vodia-mcp` if the IAM update was made after the installer ran.

## Validation target

First validate identity, available Voice Connector regions, recommendation behavior, existing Voice Connector inspection, plan generation, exact-confirmation enforcement, and creation of one disposable test Voice Connector. Do not enable downstream trunk or credential writes yet.

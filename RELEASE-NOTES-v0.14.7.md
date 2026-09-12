# Vodia MCP v0.14.7

## Fix release

This release corrects the HTTP self-test version assertion that blocked deployment of v0.14.6 even though the predefined trunk implementation passed its functional tests.

### Fixes
- Updates `test/http-selftest.js` to validate connector version `0.14.7`.
- Retains the Microsoft Teams and Amazon Chime predefined SIP trunk templates introduced in v0.14.6.
- Retains the inspect -> ask for missing provider fields -> plan -> explicit approval -> apply -> verify workflow.
- Upgrade accepts installations currently on v0.14.4, v0.14.5, or v0.14.6.

### Security
No captured SIP passwords or HAR credentials are embedded in the predefined templates. Runtime secrets remain user-supplied and redacted from plans/audit output.

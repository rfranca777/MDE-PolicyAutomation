# Contributing to MDE Policy Automation

Thank you for your interest in contributing! This project is part of [ODefender Community](https://github.com/rfranca777/odefender-community).

## How to Contribute

### Reporting Bugs

1. Check [existing issues](https://github.com/rfranca777/MDE-PolicyAutomation/issues) first
2. Open a new issue with:
   - PowerShell version (`$PSVersionTable.PSVersion`)
   - Azure CLI version (`az version`)
   - Error messages and stage number
   - Subscription type (CSP, EA, Pay-As-You-Go)

### Suggesting Features

Open an issue with the `enhancement` label. Ideas we'd especially love:

- 🐧 **Linux VM support** — bash equivalent of `Set-MDEDeviceTag.ps1`
- 📊 **Enhanced HTML reports** — compliance dashboards, trend analysis
- 🧪 **Pester tests** — automated testing for each deployment stage
- 🌐 **Multi-tenant support** — Azure Lighthouse integration

### Pull Requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Test with `reportOnly` mode first
4. Ensure no credentials or tenant-specific data are included
5. Submit a PR with a clear description

## Code Standards

- PowerShell 5.1 compatibility (no PS7-only features in core scripts)
- Use `Write-ValidationStep` for stage output consistency
- Include validation checks after each Azure resource operation
- Follow the existing naming convention: `rg-mde-{sub}`, `aa-mde-{sub}`, etc.

## Security

- **NEVER** commit credentials, tenant IDs, or subscription IDs
- Use parameterized inputs, not hardcoded values
- All sensitive operations must have a `reportOnly` / dry-run mode

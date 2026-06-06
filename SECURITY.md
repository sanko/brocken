# Security Policy

This document outlines the security policy for `brocken`.

Generating executable code is an inherently sensitive operation. This document outlines our threat model and the specific mitigations implemented to ensure the project is as safe and robust as possible.

## Supported Versions

Security updates are provided for the latest public release. As this is a pre-1.0 project, users are encouraged to stay on the most recent commit from the main development branch.

| Version       | Supported          |
| ------------- | ------------------ |
| >= 0.1.3      | :white_check_mark: |
| < 0.1.3       | :x:                |
| [unversioned] | :white_check_mark: |

## Reporting a Vulnerability

I take all security vulnerabilities seriously. To protect the project's users, I request that you report all suspected vulnerabilities to me privately.

**Please do not report security vulnerabilities through public GitHub issues.**

The preferred and most secure method for reporting is through **[GitHub's private vulnerability reporting feature](https://github.com/sanko/brocken/security/advisories/new)**. This creates a private advisory and opens a direct, secure line of communication.

If you are unable to use GitHub's reporting feature, you may send an email to [git@sankorobinson.com](mailto:git@sankorobinson.com).

Please include the following information in your report:

*   A detailed description of the vulnerability and how to reproduce it.
*   The version(s) or commit hash of the library affected.
*   Any proof-of-concept code or steps that demonstrate the issue.
*   The potential impact of the vulnerability (e.g., code execution, information disclosure).

I will do my best to acknowledge your report within 48 hours and will work with you to understand and resolve the issue. I will publicly credit you for your discovery once the vulnerability has been patched, unless you prefer to remain anonymous.

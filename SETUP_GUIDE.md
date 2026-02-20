# Salesforce CI/CD Setup Guide

## How It Works

```
Feature Branch → PR → Devmain / UAT / Production
```

| Branch | What happens on PR open | What happens on PR approval |
|--------|------------------------|----------------------------|
| `Devmain` | Nothing | Nothing. You approve + merge manually |
| `UAT` | Nothing | Validates (dry-run) → Deploys → Auto-merges |
| `Production` | Nothing | Validates (dry-run) → Deploys → Auto-merges |

---

## Setup (6 Steps)

### 1. Run the setup script

```bash
cd your-repo
bash setup-cicd.sh
```

This creates the 3 branches and both workflow files automatically.

### 2. Add GitHub Secrets

Go to: **GitHub repo → Settings → Secrets and variables → Actions**

Add these 3 secrets:

| Secret | Value |
|--------|-------|
| `SFDX_AUTH_URL_DEV` | Auth URL for Dev sandbox |
| `SFDX_AUTH_URL_UAT` | Auth URL for UAT sandbox |
| `SFDX_AUTH_URL_PROD` | Auth URL for Production org |

**How to get the auth URL:**
```bash
sf org login web --alias dev-org
sf org display --target-org dev-org --verbose --json | grep "sfdxAuthUrl"
```
Repeat for UAT and Production. The URL looks like: `force://PlatformCLI::xxxx@your-instance.salesforce.com`

### 3. Set Up Branch Protection Rules

Go to: **GitHub repo → Settings → Branches → Add rule**

Create a rule for each branch: `Devmain`, `UAT`, `Production`.

**For Devmain:**

- [x] **Require a pull request before merging**
  - [x] Require approvals: **1**
- [x] **Do not allow bypassing the above settings**

(No status checks needed — Devmain has no automated workflows)

**For UAT and Production:**

- [x] **Require a pull request before merging**
  - [x] Require approvals: **1** (or **2** for Production)
- [x] **Do not allow bypassing the above settings**

(No need to add `validate-deployment` as a required status check — the validation + deploy runs on approval, not on PR open)

### 4. Set Up Approvers (Who Can Approve PRs)

**For public repos (free):**
- Any collaborator with **Write** access or above can approve PRs
- Go to: **Settings → Collaborators → Add people**
- Give them `Write` role — they can now approve

**Quick summary of who can approve:**

| Role | Can approve PRs? |
|------|-----------------|
| Read | No |
| Triage | No |
| Write | Yes |
| Maintain | Yes |
| Admin | Yes |

**Tip:** You (the repo owner) can also approve. For Production, if you set 2 required approvals, you need 2 different people to approve.

### 5. Commit and push

```bash
git add .github/workflows/
git commit -m "Add CI/CD workflows"
git push
```

---

## Day-to-Day Usage

1. Create a feature branch, make changes, push
2. Open a PR targeting `Devmain`, `UAT`, or `Production`
3. Nothing runs automatically — the PR just waits for review
4. **Devmain:** Someone approves → you merge manually
5. **UAT / Production:** Someone approves → workflow kicks off automatically:
   - Validates (dry-run) → if passes → Deploys (real) → Auto-merges
6. If validation or deploy fails: PR stays open, check the workflow logs

**To run all tests:** Put `RUN_ALL_TESTS` in your PR title.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Auth error | Re-run `sf org login web`, get new auth URL, update the GitHub secret |
| No changes detected | Make sure metadata is in `force-app/` and in source format |
| Validation passed but deploy failed | Another deploy may be running, or someone changed the org directly |
| Auto-merge failed | Check that GITHUB_TOKEN has write permissions and there are no merge conflicts |
| Timeout | Production auto-retries. You can also run `sf project deploy resume --use-most-recent` |

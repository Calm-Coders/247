#!/bin/bash
# ============================================================
# Salesforce CI/CD Setup Script
# Creates branches: Devmain, UAT, Production
# Creates .github/workflows/ with pr-validation.yml and deploy-on-approval.yml
# ============================================================

set -e

echo "============================================"
echo " Salesforce CI/CD Setup"
echo "============================================"
echo ""

# -----------------------------------------------------------
# Step 1: Ensure we're in a git repository
# -----------------------------------------------------------
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "[ERROR] Not inside a git repository."
  echo "Please run: git init"
  echo "Then re-run this script."
  exit 1
fi

echo "[OK] Inside a git repository."

# -----------------------------------------------------------
# Step 2: Check if there's at least one commit
# -----------------------------------------------------------
if ! git log --oneline -1 &>/dev/null; then
  echo "[INFO] No commits found. Creating initial commit..."
  git commit --allow-empty -m "Initial commit"
  echo "[OK] Initial commit created."
fi

# -----------------------------------------------------------
# Step 3: Create branches (Devmain, UAT, Production)
# -----------------------------------------------------------
CURRENT_BRANCH=$(git branch --show-current)

create_branch() {
  local BRANCH_NAME="$1"
  if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    echo "[SKIP] Branch '$BRANCH_NAME' already exists locally."
  else
    git branch "$BRANCH_NAME"
    echo "[OK] Branch '$BRANCH_NAME' created."
  fi
}

echo ""
echo "--- Creating branches ---"
create_branch "Devmain"
create_branch "UAT"
create_branch "Production"

# -----------------------------------------------------------
# Step 4: Create .github/workflows/ directory
# -----------------------------------------------------------
echo ""
echo "--- Setting up .github/workflows/ ---"

if [ -d ".github/workflows" ]; then
  echo "[OK] .github/workflows/ already exists."
else
  mkdir -p .github/workflows
  echo "[OK] Created .github/workflows/"
fi

# -----------------------------------------------------------
# Step 5: Create pr-validation.yml
# -----------------------------------------------------------
echo ""
echo "--- Writing pr-validation.yml ---"

cat > .github/workflows/pr-validation.yml << 'WORKFLOW_EOF'
# ============================================================
# DISABLED - This workflow is kept for reference but does not run.
# To re-enable, uncomment the 'on:' trigger below.
# ============================================================
name: PR Validation (Disabled)

# Disabled: no automatic validation on PR open
# To re-enable, replace 'on: workflow_dispatch' with:
#
# on:
#   pull_request:
#     branches:
#       - Devmain
#       - UAT
#       - Production
#     types: [opened, synchronize, reopened]

on:
  workflow_dispatch:

# Configuration - Update these values as needed
env:
  SF_API_VERSION: '64.0'

jobs:
  validate-deployment:
    runs-on: ubuntu-latest
    timeout-minutes: 180

    steps:
      - name: Determine Target Org
        id: target-org
        run: |
          BASE_BRANCH="${{ github.event.pull_request.base.ref }}"
          HEAD_BRANCH="${{ github.event.pull_request.head.ref }}"

          echo "PR: $HEAD_BRANCH -> $BASE_BRANCH"

          # Determine which org to deploy to based on target branch
          case "$BASE_BRANCH" in
            "Devmain")
              echo "auth_url_secret=SFDX_AUTH_URL_DEV" >> $GITHUB_OUTPUT
              echo "target_org=DEV" >> $GITHUB_OUTPUT
              ;;
            "UAT")
              echo "auth_url_secret=SFDX_AUTH_URL_UAT" >> $GITHUB_OUTPUT
              echo "target_org=UAT" >> $GITHUB_OUTPUT
              ;;
            "Production")
              echo "auth_url_secret=SFDX_AUTH_URL_PROD" >> $GITHUB_OUTPUT
              echo "target_org=PROD" >> $GITHUB_OUTPUT
              ;;
          esac

      - name: Checkout Repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install Salesforce CLI
        run: |
          npm install -g @salesforce/cli
          sf --version

      - name: Install sfdx-git-delta
        run: |
          echo "y" | sf plugins install sfdx-git-delta
          sf plugins

      - name: Authenticate to Salesforce Org
        run: |
          echo "${{ secrets[steps.target-org.outputs.auth_url_secret] }}" > sfdx_auth_url.txt
          sf org login sfdx-url --sfdx-url-file sfdx_auth_url.txt --alias target-org --set-default
          rm sfdx_auth_url.txt

      - name: Generate Delta Package
        id: delta
        run: |
          mkdir -p delta-package

          # Get the merge base
          BASE_SHA=$(git merge-base origin/${{ github.event.pull_request.base.ref }} ${{ github.sha }})
          HEAD_SHA=${{ github.sha }}

          echo "Generating delta between $BASE_SHA and $HEAD_SHA"

          # Generate delta with updated flags (--output-dir and --ignore-file)
          sf sgd source delta \
            --from "$BASE_SHA" \
            --to "$HEAD_SHA" \
            --output-dir delta-package \
            --ignore-file .gitignore

          echo "=== Delta Package Contents ==="
          if [ -f "delta-package/package/package.xml" ]; then
            cat delta-package/package/package.xml
            echo "has_changes=true" >> $GITHUB_OUTPUT
          else
            echo "No metadata changes detected"
            echo "has_changes=false" >> $GITHUB_OUTPUT
          fi

          echo "=== Destructive Changes ==="
          if [ -f "delta-package/destructiveChanges/destructiveChanges.xml" ]; then
            cat delta-package/destructiveChanges/destructiveChanges.xml
          else
            echo "No destructive changes detected"
          fi

      - name: Determine Test Level
        id: test-level
        run: |
          PR_TITLE="${{ github.event.pull_request.title }}"

          # Check if PR title contains RUN_ALL_TESTS
          if [[ "$PR_TITLE" == *"RUN_ALL_TESTS"* ]]; then
            echo "PR title contains RUN_ALL_TESTS - will run all local tests"
            echo "test_level=RunLocalTests" >> $GITHUB_OUTPUT
          else
            echo "PR title does not contain RUN_ALL_TESTS - skipping tests"
            echo "test_level=NoTestRun" >> $GITHUB_OUTPUT
          fi

      - name: Validate Deployment (Check Only)
        if: steps.delta.outputs.has_changes == 'true'
        run: |
          echo "Validating deployment to ${{ steps.target-org.outputs.target_org }} org (check-only)..."
          echo "Test Level: ${{ steps.test-level.outputs.test_level }}"

          # Use --manifest only (not both --manifest and --source-dir)
          sf project deploy start \
            --manifest delta-package/package/package.xml \
            --target-org target-org \
            --test-level ${{ steps.test-level.outputs.test_level }} \
            --dry-run \
            --ignore-warnings \
            --api-version ${{ env.SF_API_VERSION }} \
            --wait 120

      - name: Report Validation Results
        if: always()
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const success = '${{ job.status }}' === 'success';
            const hasChanges = '${{ steps.delta.outputs.has_changes }}' === 'true';
            const targetOrg = '${{ steps.target-org.outputs.target_org }}';
            const baseBranch = '${{ github.event.pull_request.base.ref }}';
            const headBranch = '${{ github.event.pull_request.head.ref }}';
            const apiVersion = '${{ env.SF_API_VERSION }}';
            const testLevel = '${{ steps.test-level.outputs.test_level }}';

            let body;
            if (success) {
              if (hasChanges) {
                body = `✅ **Validation Successful**\n\n| | |\n|---|---|\n| **Source Branch** | \`${headBranch}\` |\n| **Target Branch** | \`${baseBranch}\` |\n| **Target Org** | **${targetOrg}** |\n| **API Version** | ${apiVersion} |\n| **Test Level** | ${testLevel} |\n\nThe deployment has been validated. Once this PR is approved, the changes will be deployed automatically.\n\n💡 *To run all tests, include \`RUN_ALL_TESTS\` in the PR title.*`;
              } else {
                body = `ℹ️ **No Metadata Changes Detected**\n\n| | |\n|---|---|\n| **Source Branch** | \`${headBranch}\` |\n| **Target Branch** | \`${baseBranch}\` |\n\nNo Salesforce metadata changes found in this PR.`;
              }
            } else {
              body = `❌ **Validation Failed**\n\n| | |\n|---|---|\n| **Source Branch** | \`${headBranch}\` |\n| **Target Branch** | \`${baseBranch}\` |\n| **Target Org** | **${targetOrg}** |\n| **API Version** | ${apiVersion} |\n\nPlease check the [workflow logs](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}) for details.`;
            }

            // Find existing comment
            const { data: comments } = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.payload.pull_request.number,
            });

            const botComment = comments.find(comment =>
              comment.user.type === 'Bot' &&
              comment.body.includes('Validation')
            );

            if (botComment) {
              await github.rest.issues.updateComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                comment_id: botComment.id,
                body: body
              });
            } else {
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: context.payload.pull_request.number,
                body: body
              });
            }
WORKFLOW_EOF

echo "[OK] pr-validation.yml created."

# -----------------------------------------------------------
# Step 6: Create deploy-on-approval.yml
# -----------------------------------------------------------
echo ""
echo "--- Writing deploy-on-approval.yml ---"

cat > .github/workflows/deploy-on-approval.yml << 'WORKFLOW_EOF'
name: Deploy on PR Approval

on:
  pull_request_review:
    types: [submitted]

# Configuration - Update these values as needed
env:
  SF_API_VERSION: '64.0'

jobs:
  validate-and-deploy-on-approval:
    # Only run when PR is approved AND targets UAT or Production
    if: >-
      github.event.review.state == 'approved' &&
      (github.event.pull_request.base.ref == 'UAT' || github.event.pull_request.base.ref == 'Production')
    runs-on: ubuntu-latest
    timeout-minutes: 180

    steps:
      - name: Determine Target Org
        id: target-org
        run: |
          BASE_BRANCH="${{ github.event.pull_request.base.ref }}"
          HEAD_BRANCH="${{ github.event.pull_request.head.ref }}"

          echo "PR: $HEAD_BRANCH -> $BASE_BRANCH"

          case "$BASE_BRANCH" in
            "UAT")
              echo "target_org=UAT" >> $GITHUB_OUTPUT
              echo "auth_url_secret=SFDX_AUTH_URL_UAT" >> $GITHUB_OUTPUT
              ;;
            "Production")
              echo "target_org=PROD" >> $GITHUB_OUTPUT
              echo "auth_url_secret=SFDX_AUTH_URL_PROD" >> $GITHUB_OUTPUT
              ;;
          esac

      - name: Checkout Repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install Salesforce CLI
        run: |
          npm install -g @salesforce/cli
          sf --version

      - name: Install sfdx-git-delta
        run: |
          echo "y" | sf plugins install sfdx-git-delta
          sf plugins

      - name: Authenticate to Salesforce Org
        run: |
          echo "${{ secrets[steps.target-org.outputs.auth_url_secret] }}" > sfdx_auth_url.txt
          sf org login sfdx-url --sfdx-url-file sfdx_auth_url.txt --alias target-org --set-default
          rm sfdx_auth_url.txt

      - name: Generate Delta Package
        id: delta
        run: |
          mkdir -p delta-package

          # Get the merge base between the PR branch and target branch
          BASE_SHA=$(git merge-base origin/${{ github.event.pull_request.base.ref }} ${{ github.event.pull_request.head.sha }})
          HEAD_SHA=${{ github.event.pull_request.head.sha }}

          echo "Generating delta between $BASE_SHA and $HEAD_SHA"

          sf sgd source delta \
            --from "$BASE_SHA" \
            --to "$HEAD_SHA" \
            --output-dir delta-package \
            --ignore-file .gitignore

          echo "=== Delta Package Contents ==="
          if [ -f "delta-package/package/package.xml" ]; then
            cat delta-package/package/package.xml
            echo "has_changes=true" >> $GITHUB_OUTPUT
          else
            echo "No changes detected in package.xml"
            echo "has_changes=false" >> $GITHUB_OUTPUT
          fi

          echo "=== Destructive Changes ==="
          if [ -f "delta-package/destructiveChanges/destructiveChanges.xml" ]; then
            cat delta-package/destructiveChanges/destructiveChanges.xml
          else
            echo "No destructive changes detected"
          fi

      - name: Determine Test Level
        id: test-level
        run: |
          PR_TITLE="${{ github.event.pull_request.title }}"

          if [[ "$PR_TITLE" == *"RUN_ALL_TESTS"* ]]; then
            echo "PR title contains RUN_ALL_TESTS - will run all local tests"
            echo "test_level=RunLocalTests" >> $GITHUB_OUTPUT
          else
            echo "PR title does not contain RUN_ALL_TESTS - skipping tests"
            echo "test_level=NoTestRun" >> $GITHUB_OUTPUT
          fi

      # ============================================================
      # VALIDATION GATE: Dry-run check before actual deployment
      # If this fails, the workflow stops and the PR is NOT merged
      # ============================================================
      - name: Validate Deployment (Dry-Run Check)
        if: steps.delta.outputs.has_changes == 'true'
        id: validation
        run: |
          echo "Running validation (dry-run) against ${{ steps.target-org.outputs.target_org }} org..."
          echo "Test Level: ${{ steps.test-level.outputs.test_level }}"

          sf project deploy start \
            --manifest delta-package/package/package.xml \
            --target-org target-org \
            --test-level ${{ steps.test-level.outputs.test_level }} \
            --dry-run \
            --ignore-warnings \
            --api-version ${{ env.SF_API_VERSION }} \
            --wait 120

          echo "validation_passed=true" >> $GITHUB_OUTPUT
          echo "Validation passed! Proceeding to deployment..."

      - name: Comment Validation Passed
        if: steps.delta.outputs.has_changes == 'true' && steps.validation.outputs.validation_passed == 'true'
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const targetOrg = '${{ steps.target-org.outputs.target_org }}';
            const baseBranch = '${{ github.event.pull_request.base.ref }}';
            const headBranch = '${{ github.event.pull_request.head.ref }}';
            const apiVersion = '${{ env.SF_API_VERSION }}';
            const testLevel = '${{ steps.test-level.outputs.test_level }}';

            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.payload.pull_request.number,
              body: `🔍 **Pre-Deploy Validation Passed**\n\n| | |\n|---|---|\n| **Source Branch** | \`${headBranch}\` |\n| **Target Branch** | \`${baseBranch}\` |\n| **Target Org** | **${targetOrg}** |\n| **API Version** | ${apiVersion} |\n| **Test Level** | ${testLevel} |\n\nValidation successful. Now deploying to ${targetOrg} org...`
            });

      # ============================================================
      # DEPLOYMENT: Only runs if validation passed
      # ============================================================
      - name: Deploy Delta to Salesforce
        if: steps.delta.outputs.has_changes == 'true' && steps.validation.outputs.validation_passed == 'true'
        id: deploy
        run: |
          echo "Deploying delta package to ${{ steps.target-org.outputs.target_org }} org..."
          echo "Test Level: ${{ steps.test-level.outputs.test_level }}"

          sf project deploy start \
            --manifest delta-package/package/package.xml \
            --target-org target-org \
            --test-level ${{ steps.test-level.outputs.test_level }} \
            --ignore-warnings \
            --api-version ${{ env.SF_API_VERSION }} \
            --wait 120

          echo "deployment_success=true" >> $GITHUB_OUTPUT

      - name: Deploy (No Changes)
        if: steps.delta.outputs.has_changes != 'true'
        id: deploy-no-changes
        run: |
          echo "No metadata changes to deploy"
          echo "deployment_success=true" >> $GITHUB_OUTPUT

      - name: Handle Destructive Changes
        if: steps.deploy.outputs.deployment_success == 'true'
        run: |
          if [ -f "delta-package/destructiveChanges/destructiveChanges.xml" ]; then
            echo "Deploying destructive changes..."
            sf project deploy start \
              --manifest delta-package/destructiveChanges/destructiveChanges.xml \
              --target-org target-org \
              --post-destructive-changes delta-package/destructiveChanges/destructiveChanges.xml \
              --ignore-warnings \
              --api-version ${{ env.SF_API_VERSION }} \
              --wait 60
          else
            echo "No destructive changes to deploy"
          fi

      - name: Resume Deployment if Needed (Production Only)
        if: failure() && steps.target-org.outputs.target_org == 'PROD'
        run: |
          echo "Attempting to resume the most recent deployment..."
          sf project deploy resume --use-most-recent || echo "No deployment to resume"

      - name: Auto-Merge PR on Successful Deployment
        if: steps.deploy.outputs.deployment_success == 'true' || steps.deploy-no-changes.outputs.deployment_success == 'true'
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const prNumber = context.payload.pull_request.number;
            const targetOrg = '${{ steps.target-org.outputs.target_org }}';
            const baseBranch = '${{ github.event.pull_request.base.ref }}';
            const headBranch = '${{ github.event.pull_request.head.ref }}';
            const apiVersion = '${{ env.SF_API_VERSION }}';

            try {
              // Merge the PR
              await github.rest.pulls.merge({
                owner: context.repo.owner,
                repo: context.repo.repo,
                pull_number: prNumber,
                merge_method: 'squash',
                commit_title: `Merge PR #${prNumber}: ${context.payload.pull_request.title}`,
                commit_message: `Deployed successfully to ${targetOrg} org\n\nSource: ${headBranch}\nTarget: ${baseBranch}\nAPI Version: ${apiVersion}`
              });

              console.log(`Successfully merged PR #${prNumber}`);

              const testLevel = '${{ steps.test-level.outputs.test_level }}';

              // Add a comment
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: prNumber,
                body: `✅ **Deployment Successful!**\n\n| | |\n|---|---|\n| **Source Branch** | \`${headBranch}\` |\n| **Target Branch** | \`${baseBranch}\` |\n| **Deployed To** | **${targetOrg}** |\n| **API Version** | ${apiVersion} |\n| **Test Level** | ${testLevel} |\n\nPR has been automatically merged.`
              });

            } catch (error) {
              console.error('Failed to merge PR:', error);

              // Add failure comment
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: prNumber,
                body: `⚠️ **Deployment succeeded but auto-merge failed**\n\n| | |\n|---|---|\n| **Source Branch** | \`${headBranch}\` |\n| **Target Branch** | \`${baseBranch}\` |\n| **Deployed To** | **${targetOrg}** |\n| **API Version** | ${apiVersion} |\n\nPlease merge manually.\nError: ${error.message}`
              });

              throw error;
            }

      # ============================================================
      # FAILURE COMMENTS
      # ============================================================
      - name: Comment on Validation Failure
        if: failure() && steps.delta.outputs.has_changes == 'true' && steps.validation.outputs.validation_passed != 'true'
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const targetOrg = '${{ steps.target-org.outputs.target_org }}';
            const baseBranch = '${{ github.event.pull_request.base.ref }}';
            const headBranch = '${{ github.event.pull_request.head.ref }}';
            const apiVersion = '${{ env.SF_API_VERSION }}';

            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.payload.pull_request.number,
              body: `❌ **Pre-Deploy Validation Failed!**\n\n| | |\n|---|---|\n| **Source Branch** | \`${headBranch}\` |\n| **Target Branch** | \`${baseBranch}\` |\n| **Target Org** | **${targetOrg}** |\n| **API Version** | ${apiVersion} |\n\nThe delta deployment check (dry-run) failed. The changes are **NOT deployable** to the ${targetOrg} org.\n\nPlease check the [workflow logs](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}) for details.\n\n⛔ The PR will NOT be merged. Fix the issues and request a new review.`
            });

      - name: Comment on Deployment Failure
        if: failure() && steps.validation.outputs.validation_passed == 'true'
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const targetOrg = '${{ steps.target-org.outputs.target_org }}';
            const baseBranch = '${{ github.event.pull_request.base.ref }}';
            const headBranch = '${{ github.event.pull_request.head.ref }}';
            const apiVersion = '${{ env.SF_API_VERSION }}';

            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.payload.pull_request.number,
              body: `❌ **Deployment Failed!**\n\n| | |\n|---|---|\n| **Source Branch** | \`${headBranch}\` |\n| **Target Branch** | \`${baseBranch}\` |\n| **Target Org** | **${targetOrg}** |\n| **API Version** | ${apiVersion} |\n\nValidation passed but the actual deployment failed.\n\nPlease check the [workflow logs](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}) for details.\n\nThe PR will NOT be merged until deployment succeeds.`
            });
WORKFLOW_EOF

echo "[OK] deploy-on-approval.yml created."

# -----------------------------------------------------------
# Step 7: Push branches to remote (if remote exists)
# -----------------------------------------------------------
echo ""
echo "--- Pushing branches to remote ---"

if git remote get-url origin &>/dev/null; then
  echo "[INFO] Remote 'origin' found. Pushing branches..."

  for BRANCH in Devmain UAT Production; do
    if git ls-remote --heads origin "$BRANCH" | grep -q "$BRANCH"; then
      echo "[SKIP] Branch '$BRANCH' already exists on remote."
    else
      git push -u origin "$BRANCH" 2>/dev/null && echo "[OK] Pushed '$BRANCH' to remote." || echo "[WARN] Could not push '$BRANCH'. You may need to push manually."
    fi
  done
else
  echo "[WARN] No remote 'origin' found. Skipping push."
  echo "       After adding a remote, run:"
  echo "         git push -u origin Devmain"
  echo "         git push -u origin UAT"
  echo "         git push -u origin Production"
fi

# -----------------------------------------------------------
# Step 8: Switch back to original branch
# -----------------------------------------------------------
git checkout "$CURRENT_BRANCH" 2>/dev/null || true

# -----------------------------------------------------------
# Done!
# -----------------------------------------------------------
echo ""
echo "============================================"
echo " Setup Complete!"
echo "============================================"
echo ""
echo " Branches created: Devmain, UAT, Production"
echo ""
echo " Workflow files:"
echo "   .github/workflows/pr-validation.yml"
echo "   .github/workflows/deploy-on-approval.yml"
echo ""
echo " Flow summary:"
echo "   Devmain:    No workflows. Manual approve + merge."
echo ""
echo "   UAT:        On approval -> validate (dry-run)"
echo "               -> deploy -> auto-merge."
echo ""
echo "   Production: On approval -> validate (dry-run)"
echo "               -> deploy -> auto-merge."
echo ""
echo " Required GitHub Secrets:"
echo "   SFDX_AUTH_URL_DEV"
echo "   SFDX_AUTH_URL_UAT"
echo "   SFDX_AUTH_URL_PROD"
echo ""
echo " Next steps:"
echo "   1. Commit and push the workflow files"
echo "   2. Configure branch protection rules in GitHub"
echo "   3. Add required status check: 'validate-deployment'"
echo "============================================"

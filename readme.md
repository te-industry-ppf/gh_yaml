# Setup

## Add AZURE_DEVOPS_PAT to secrets

To use the Azure DevOps API, you need to create a Personal Access Token (PAT) and add it to your repository secrets.
1. Go to your Azure DevOps organization and navigate to User Settings > Personal Access Tokens.
2. Click on "New Token" and fill in the required details. Make sure to select the appropriate scopes for your token (Azure Artifacts).
3. Once the token is created, copy it and go to your GitHub repository.
4. Navigate to Settings > Secrets and click on "New repository secret".
5. Name the secret `AZURE_DEVOPS_PAT` and paste the copied token as the value.
6. Click "Add secret" to save it.
Now you can use the `AZURE_DEVOPS_PAT` secret in your GitHub Actions workflows to authenticate with the Azure DevOps API.
# Suit Tracker Insights – Deployment Notes

## 1. Backend container

### Changes made

- The `insights` table was not created when the server started. Because of this, `GET /insights` returned a 500 error when using a fresh database. I added `CREATE TABLE IF NOT EXISTS` to create the table automatically at startup.
- The `/insights` endpoint was using `body = 200` instead of `status = 200`. This caused the response data to be replaced with the number `200`. I corrected this.
- The `deno compile` command did not include the required permission flags. This meant the application could ask for permissions at runtime. I added the required flags during compilation.
- The server was only listening on the local interface. The container health check passed, but requests from outside the container could not reach it. I changed it to listen on `0.0.0.0`.

### Dockerfile

I created a multi-stage Docker build. The first stage compiles the application using the Deno image, and the final image uses `debian:bookworm-slim` and contains only the compiled binary and the required runtime dependencies.

Other changes include:

- Running the application as a non-root user.
- Using the system's `libsqlite3` library and setting `DENO_SQLITE_PATH`. This avoids downloading the native SQLite library from GitHub when the application starts, which may not work in restricted networks.
- Storing the database under `/data` so it can use a persistent volume.
- Setting `SERVER_PORT` in the Docker image because the `.env` file is only available in the development environment.
- Adding a health check for `/_health`.

### Testing

I built the Docker image and ran the container. I checked `/_health` and `/insights` from outside the container to make sure both endpoints were accessible.

I also ran the container with `--network none` and `--read-only`. This helped confirm that the application could run without internet access and that it only needed to write data under `/data`.

## 2. Deploying the frontend

The frontend build produces static files under `client/build/`. These files can be hosted on AWS using S3 and CloudFront.

The main things needed for production are:

- **Hosting:** Use a private S3 bucket and CloudFront with Origin Access Control so the files cannot be accessed directly from the bucket.
- **Domain and HTTPS:** Configure a Route 53 record and an ACM certificate. For CloudFront, the certificate must be created in `us-east-1`.
- **Frontend routing:** The application is a single-page app, so unknown paths should return `index.html`. CloudFront can be configured to handle 403 and 404 responses this way.
- **API routing:** In development, Vite proxies requests under `/api` to the backend and removes the `/api` prefix. Production needs equivalent routing through CloudFront to an ALB in front of the ECS service. The prefix must also be removed before the request reaches the backend. Using the same domain for the frontend and API avoids the need for CORS configuration between them.
- **Caching:** Cache files under `assets/` for one year because they have hashed filenames. Do not cache `index.html`, so users receive the latest version after a deployment.
- **Security:** Add a response headers policy for security headers such as HSTS and CSP, and configure AWS WAF to limit excessive requests.

### Main blocker

There is currently no authentication or authorisation. This means users could potentially access insights belonging to other customers.

We should not expose the application publicly until login and access controls for each brand are implemented. For an initial release, we could restrict access using a WAF IP allowlist or basic authentication as a temporary measure.

## 3. CI/CD pipeline

A GitHub Actions workflow runs whenever someone opens or updates a pull request, or pushes changes to `main`.

The workflow:

- Type-checks and tests the server and shared library, and runs the client tests.
- Builds the frontend.
- Builds the Docker image, starts the container, and checks that `/_health` and `/insights` return responses.

There is also a `deploy` job showing how we plan to release the application. It uses GitHub Actions OIDC to connect to AWS without storing long-lived access keys. It then pushes a Docker image tagged with the commit SHA, deploys it to ECS, uploads the frontend files to S3, invalidates the CloudFront cache, and requires approval before a production deployment.

Deployment is currently disabled because the AWS infrastructure is not in place yet. It can be enabled by setting `DEPLOY_ENABLED`.

### Still to do

- The current example uses `--force-new-deployment`, which reuses the existing ECS task definition. Before deploying, the pipeline should register a new task definition revision that points to the new image tag.
- Client type-checking is not included because it currently fails due to issues in the existing code. See Section 7.

## 4. Monitoring and observability

We already use Datadog, so the plan is to use it for application monitoring as well. These monitoring changes have not been set up yet.

### What we need in Datadog

- **Datadog Agent:** Run the Agent alongside the application in the ECS task so it can collect container metrics, logs and APM data.
- **Logs:** Send the container's standard output to Datadog. Logs should be structured JSON and include a request ID, making it easier to search for errors and follow a request. Health-check requests to `/_health` should be excluded from routine logs where possible to reduce noise.
- **Infrastructure metrics:** Use the ECS, ALB and CloudFront integrations to monitor CPU and memory usage, task restarts, 5xx errors and latency. If the database uses an EBS volume, monitor available disk space as well.
- **APM:** Collect traces and monitor request rates, errors and latency for each API endpoint. A service map would also help us understand the connections between services. First, we need to confirm that Datadog's tracing support works with Deno. If it does not, we will need another way to send trace data to the Datadog Agent.
- **Synthetic monitoring:**
  - Run an API test every minute against the public URL to check `/_health` and `/insights`, including the HTTP status and whether the response contains valid JSON.
  - Run a browser test that opens the frontend and checks that the insights list appears.
  - Run these tests from more than one location so we can detect issues that customers may experience outside our own network.
- **Real User Monitoring (RUM) and error tracking:** Monitor frontend JavaScript errors and slow page loads experienced by real users.
- **SLOs and alerts:**
  - Define a Datadog SLO where 99.9% of `/insights` requests succeed over 30 days, with p95 latency below 300 ms.
  - Page the on-call person when the error budget is being used up quickly. For slower burn rates, create a ticket.
  - Add monitors for failed synthetic tests, high 5xx rates, high p95 latency, task restarts and low disk space.
  - Include a runbook link in each alert and send notifications to Slack and the on-call person.
- **Dashboard:** Create a service dashboard showing the main signals: traffic, errors, latency and resource usage.

### Changes needed in the code

- Replace `console.log` with structured JSON logging that includes a request ID. The current code prints free text and sometimes logs entire result sets.
- Add middleware to generate request IDs and handle errors consistently.
- Keep `/_health` as a simple liveness check and add `/_ready` to check whether the database is available. This helps distinguish between a process that is running and a service that is ready to handle requests.
- Handle `SIGTERM` so the application can shut down cleanly during deployments.
- Add request metrics and tracing so Datadog APM can show useful information.

### SQLite and monitoring

Datadog database monitoring supports databases such as PostgreSQL, but not SQLite. This is another reason to consider moving to PostgreSQL, as discussed in Section 5.

## 5. SQLite

SQLite is fast because it runs inside the application, but it has some limitations when used on ECS.

- **Writes and scaling:** SQLite allows only one writer at a time. For this setup, we should run a single application task rather than scale out horizontally.
- **Deployments:** A rolling deployment may briefly run two tasks that try to use the same database file. We should use a stop-then-start deployment instead, accepting a short period of downtime.
- **Storage:** Data on the container's local disk can be lost when the container is replaced. The database therefore needs persistent storage, such as an EBS volume. EFS is not a good default choice because of SQLite's file-locking requirements.
- **Backups:** Set up regular backups and test the restore process to make sure we can recover the database when needed.

### Recommendation

SQLite should be fine for a small first release, as long as we accept its scaling and availability limits.

Once there is real customer traffic or a need to run more than one application task, I recommend moving to PostgreSQL on Amazon RDS. It fits our existing stack and can also be monitored using Datadog's database monitoring features.

## 6. Scaling the engineering team from 4 to 20

As the team grows, we need consistent ways to build, deploy and operate services without every team having to set everything up from scratch.

- **Golden path:** Provide a service template that already includes a Dockerfile, CI/CD pipeline, infrastructure code, Datadog dashboard and monitors. This makes the recommended approach the easiest one to follow.
- **Environments:** Set up a staging environment and temporary environments for pull requests where they are useful.
- **Pipeline guardrails:** Make CI checks, code-owner reviews and image scanning part of the normal pipeline rather than relying on manual checks.
- **Infrastructure as code:** Use shared Terraform modules and review infrastructure changes through pull requests.
- **Observability by default:** Define Datadog dashboards, monitors and SLOs as code so new services get the basic monitoring setup automatically.
- **Incident management:** Establish an on-call rotation, clear severity levels, runbooks and blameless post-incident reviews. Track follow-up actions through to completion.
- **Access and security:** Use short-lived credentials with the minimum permissions needed for CI pipelines and other automated processes.
- **Documentation:** Maintain architecture decision records and onboarding guides so engineers can understand key decisions and get up to speed more easily.

## 7. Issues noticed but not fixed

The following issues are outside the deployment work and should be handed over for the next developer to address.

- **Frontend and backend data mismatch:** The client expects `brandId` and `date`, while the server returns `brand` and `createdAt`. These fields need to be aligned. Also, `app.tsx` stores a Promise in state and uses the wrong state type, which causes `deno check` to fail on the client.
- **Add and delete functionality:** The add and delete buttons do not work yet. The create and delete routes are also implemented as GET stubs, and the `/insights/:id` route may match those requests first.
- **SQL injection risk:** `insertStatement` builds SQL using string interpolation. It should be changed to use parameterised queries.
- **Missing authentication and authorisation:** There is no login or access control. This needs to be addressed before the application is made available to customers.
- **Missing pagination:** The `/insights` endpoint does not support pagination. This should be added before the amount of data becomes too large to return in a single response.

"""
Jira Cloud REST API v3 Client
Zero-dependency client using Python standard library (urllib.request)
Designed for AWS Lambda runtime without external pip packaging requirements.
"""

import os
import json
import base64
import logging
import urllib.request
import urllib.error
from typing import Dict, Any, Optional, List

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())


class JiraClientError(Exception):
    """Custom exception for Jira API client errors."""
    def __init__(self, message: str, status_code: Optional[int] = None, response_body: Optional[str] = None):
        super().__init__(message)
        self.status_code = status_code
        self.response_body = response_body


class JiraClient:
    """Client for interacting with Atlassian Jira Cloud REST API v3."""

    def __init__(self, base_url: str, user_email: str, api_token: str, default_project_key: str = "OPS", default_issue_type: str = "Incident"):
        self.base_url = base_url.rstrip("/")
        self.user_email = user_email.strip()
        self.api_token = api_token.strip()
        self.default_project_key = default_project_key
        self.default_issue_type = default_issue_type

        # Base64 encode basic authentication
        credentials = f"{self.user_email}:{self.api_token}"
        self.auth_header = f"Basic {base64.b64encode(credentials.encode('utf-8')).decode('utf-8')}"

    def _request(self, method: str, endpoint: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Execute an HTTP request against the Jira REST API."""
        url = f"{self.base_url}{endpoint}"
        headers = {
            "Authorization": self.auth_header,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "AWS-DevOps-Agent-Integration/1.0"
        }

        data_bytes = None
        if payload is not None:
            data_bytes = json.dumps(payload).encode("utf-8")

        req = urllib.request.Request(url, data=data_bytes, headers=headers, method=method)

        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = resp.read().decode("utf-8")
                if not body:
                    return {}
                return json.loads(body)
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8") if e.fp else ""
            logger.error(f"Jira API HTTPError {e.code} on {method} {url}: {err_body}")
            raise JiraClientError(f"Jira API Error [{e.code}]: {err_body}", status_code=e.code, response_body=err_body)
        except urllib.error.URLError as e:
            logger.error(f"Jira API URLError on {method} {url}: {e.reason}")
            raise JiraClientError(f"Jira Network Error: {e.reason}")
        except Exception as e:
            logger.error(f"Unexpected error calling Jira API {url}: {str(e)}")
            raise JiraClientError(f"Unexpected Error: {str(e)}")

    def test_connection(self) -> Dict[str, Any]:
        """Test authentication and connectivity against Jira Cloud."""
        return self._request("GET", "/rest/api/3/myself")

    def get_project(self, project_key: Optional[str] = None) -> Dict[str, Any]:
        """Verify project existence and fetch project metadata."""
        key = project_key or self.default_project_key
        return self._request("GET", f"/rest/api/3/project/{key}")

    def create_issue(
        self,
        summary: str,
        description_adf: Dict[str, Any],
        project_key: Optional[str] = None,
        issue_type: Optional[str] = None,
        labels: Optional[List[str]] = None,
        priority: Optional[str] = None,
        extra_fields: Optional[Dict[str, Any]] = None
    ) -> Dict[str, Any]:
        """
        Create a new Jira issue using REST API v3 and Atlassian Document Format (ADF).
        """
        project = project_key or self.default_project_key
        itype = issue_type or self.default_issue_type
        issue_labels = labels or ["aws-devops-agent", "automated-investigation"]

        fields: Dict[str, Any] = {
            "project": {"key": project},
            "summary": summary[:255],  # Jira max summary length
            "description": description_adf,
            "issuetype": {"name": itype},
            "labels": issue_labels
        }

        if priority:
            fields["priority"] = {"name": priority}

        if extra_fields:
            fields.update(extra_fields)

        payload = {"fields": fields}
        logger.info(f"Creating Jira issue in project {project} with type {itype}...")
        resp = self._request("POST", "/rest/api/3/issue", payload)
        logger.info(f"Created Jira issue: {resp.get('key')} (id: {resp.get('id')})")
        return resp

    def add_comment(self, issue_key: str, comment_adf: Dict[str, Any]) -> Dict[str, Any]:
        """Add a comment with Atlassian Document Format (ADF) to an existing Jira issue."""
        payload = {"body": comment_adf}
        logger.info(f"Adding comment to Jira issue {issue_key}...")
        return self._request("POST", f"/rest/api/3/issue/{issue_key}/comment", payload)

    def update_issue_labels(self, issue_key: str, add_labels: List[str]) -> Dict[str, Any]:
        """Add labels to an existing Jira issue."""
        payload = {
            "update": {
                "labels": [{"add": label} for label in add_labels]
            }
        }
        return self._request("PUT", f"/rest/api/3/issue/{issue_key}", payload)

    def transition_issue(self, issue_key: str, transition_name: str) -> bool:
        """Find and execute a workflow transition by name (e.g., 'In Progress', 'Done')."""
        try:
            transitions_data = self._request("GET", f"/rest/api/3/issue/{issue_key}/transitions")
            transitions = transitions_data.get("transitions", [])
            for t in transitions:
                if t.get("name", "").lower() == transition_name.lower():
                    tid = t.get("id")
                    self._request("POST", f"/rest/api/3/issue/{issue_key}/transitions", {"transition": {"id": tid}})
                    logger.info(f"Transitioned issue {issue_key} using transition '{transition_name}' (id: {tid})")
                    return True
            logger.warning(f"Transition '{transition_name}' not available for issue {issue_key}")
            return False
        except Exception as e:
            logger.warning(f"Failed to transition issue {issue_key} to '{transition_name}': {str(e)}")
            return False


class ADFBuilder:
    """Helper to generate Jira Cloud REST API v3 Atlassian Document Format (ADF) structures."""

    @staticmethod
    def create_doc() -> Dict[str, Any]:
        return {
            "version": 1,
            "type": "doc",
            "content": []
        }

    @staticmethod
    def paragraph(text: str, bold: bool = False, italic: bool = False) -> Dict[str, Any]:
        marks = []
        if bold:
            marks.append({"type": "strong"})
        if italic:
            marks.append({"type": "em"})

        node = {
            "type": "paragraph",
            "content": [
                {
                    "type": "text",
                    "text": text,
                    "marks": marks
                }
            ]
        }
        if not marks:
            node["content"][0].pop("marks", None)
        return node

    @staticmethod
    def heading(text: str, level: int = 2) -> Dict[str, Any]:
        return {
            "type": "heading",
            "attrs": {"level": max(1, min(level, 6))},
            "content": [{"type": "text", "text": text}]
        }

    @staticmethod
    def panel(text: str, panel_type: str = "info") -> Dict[str, Any]:
        """panel_type can be: info, note, success, warning, error"""
        return {
            "type": "panel",
            "attrs": {"panelType": panel_type},
            "content": [
                {
                    "type": "paragraph",
                    "content": [{"type": "text", "text": text}]
                }
            ]
        }

    @staticmethod
    def code_block(code: str, language: str = "json") -> Dict[str, Any]:
        return {
            "type": "codeBlock",
            "attrs": {"language": language},
            "content": [{"type": "text", "text": code}]
        }

    @staticmethod
    def bullet_list(items: List[str]) -> Dict[str, Any]:
        list_items = []
        for item in items:
            list_items.append({
                "type": "listItem",
                "content": [
                    {
                        "type": "paragraph",
                        "content": [{"type": "text", "text": item}]
                    }
                ]
            })
        return {
            "type": "bulletList",
            "content": list_items
        }

    @staticmethod
    def link_paragraph(prefix_text: str, link_text: str, href: str) -> Dict[str, Any]:
        return {
            "type": "paragraph",
            "content": [
                {"type": "text", "text": prefix_text + " "},
                {
                    "type": "text",
                    "text": link_text,
                    "marks": [
                        {
                            "type": "link",
                            "attrs": {"href": href}
                        }
                    ]
                }
            ]
        }

package skills

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// sandboxPreamble is prepended to every agent prompt file to inform the agent
// about its sandbox environment capabilities.
const sandboxPreamble = `## Sandbox Environment

You are running inside an isolated nanosandbox VM (Debian Linux). You have:
- Full sudo access (passwordless) — use it freely to install packages and tools.
- Node.js is pre-installed. Other runtimes (Python, Go, Rust, etc.) are NOT.
- When a task requires a runtime or tool that is missing, install it yourself
  using ` + "`sudo apt-get update && sudo apt-get install -y <package>`" + ` before proceeding.
  Do NOT ask the user to install software — you have full permissions to do it.
- The working directory is /workspace (project files are mounted here).
- Network access is available for downloading packages and dependencies.

`

// GenerateAllConfigs writes skill files and prompt files for configured agents.
// When an agent type is set, only generates for that type; otherwise generates for all.
func (m *Manager) GenerateAllConfigs() error {
	m.mu.RLock()
	defer m.mu.RUnlock()

	// If agent type is set, only generate for that specific type.
	if m.agentType != "" {
		agentCfg, ok := agentConfigs[m.agentType]
		if !ok {
			log.Printf("[skills] unknown agent type %q, generating for all agents", m.agentType)
		} else {
			return m.generateForAgentLocked(m.agentType, agentCfg)
		}
	}

	for agentName, agentCfg := range agentConfigs {
		if err := m.generateForAgentLocked(agentName, agentCfg); err != nil {
			return fmt.Errorf("generating skills for %s: %w", agentName, err)
		}
	}
	return nil
}

func (m *Manager) generateForAgentLocked(agentName string, cfg *AgentSkillConfig) error {
	switch cfg.Format {
	case "claude":
		if err := generateClaudeSkills(cfg.SkillsDir, m.skills); err != nil {
			return err
		}
		return generateClaudePrompt(cfg.PromptFile, m.agentName, m.agentPrompt)
	case "goose":
		return generateGooseAll(cfg.PromptFile, m.agentName, m.agentPrompt, m.skills)
	case "codex":
		if err := generateSkillMDFiles(cfg.SkillsDir, m.skills); err != nil {
			return err
		}
		return generateCodexAll(cfg.PromptFile, m.agentName, m.agentPrompt, m.skills)
	case "cursor":
		if err := generateSkillMDFiles(cfg.SkillsDir, m.skills); err != nil {
			return err
		}
		return generateCursorAll(cfg.PromptFile, m.agentName, m.agentPrompt, m.skills)
	default:
		log.Printf("[skills] unknown format %q for agent %s, skipping", cfg.Format, agentName)
		return nil
	}
}

// --- Claude Code Format ---
// Skills: /workspace/.claude/skills/<name>/SKILL.md
// Prompt: /workspace/CLAUDE.md

func generateClaudeSkills(skillsDir string, skills map[string]*SkillDef) error {
	return generateSkillMDFiles(skillsDir, skills)
}

func generateClaudePrompt(path, agentName, prompt string) error {
	content := fmt.Sprintf("<!-- nanosandbox agent: %s -->\n\n%s%s\n", agentName, sandboxPreamble, prompt)
	return writeFile(path, []byte(content))
}

// --- Goose Format ---
// Goose has no native SKILL.md. Everything goes into .goosehints.
// Prompt + skills concatenated into a single file.

func generateGooseAll(path, agentName, prompt string, skills map[string]*SkillDef) error {
	var b strings.Builder

	// Sandbox environment preamble (always included)
	b.WriteString(sandboxPreamble)

	// Agent prompt section
	if agentName != "" || prompt != "" {
		b.WriteString(fmt.Sprintf("<!-- nanosandbox agent: %s -->\n", agentName))
		b.WriteString(prompt)
		b.WriteString("\n\n")
	}

	// Skills sections
	names := sortedSkillNames(skills)
	for _, name := range names {
		skill := skills[name]
		b.WriteString(fmt.Sprintf("<!-- nanosandbox skill: %s -->\n", name))
		b.WriteString(fmt.Sprintf("## %s\n\n", skill.Name))
		if skill.Description != "" {
			b.WriteString(skill.Description + "\n\n")
		}
		b.WriteString(skill.Content)
		b.WriteString("\n\n")
	}

	if b.Len() == 0 {
		return nil
	}
	return writeFile(path, []byte(b.String()))
}

// --- Codex Format ---
// Skills: embedded in AGENTS.md via HTML comment section markers
// Prompt: /home/developer/.codex/AGENTS.md

func generateCodexPrompt(path, agentName, prompt string) error {
	return generateCodexAll(path, agentName, prompt, nil)
}

func generateCodexAll(path, agentName, prompt string, skillsMap map[string]*SkillDef) error {
	var b strings.Builder
	fmt.Fprintf(&b, "<!-- nanosandbox agent: %s -->\n\n", agentName)
	b.WriteString(sandboxPreamble)
	b.WriteString(prompt)
	b.WriteString("\n")
	writeEmbeddedSkills(&b, skillsMap)
	return writeFile(path, []byte(b.String()))
}

// --- Cursor Format ---
// Skills: embedded in rules file via HTML comment section markers
// Prompt: /home/developer/.cursor/rules/nanosandbox-agent.mdc (with alwaysApply frontmatter)

func generateCursorPrompt(path, agentName, prompt string) error {
	return generateCursorAll(path, agentName, prompt, nil)
}

func generateCursorAll(path, agentName, prompt string, skillsMap map[string]*SkillDef) error {
	var b strings.Builder
	b.WriteString("---\n")
	fmt.Fprintf(&b, "description: \"Nanosandbox agent definition: %s\"\n", agentName)
	b.WriteString("alwaysApply: true\n")
	b.WriteString("---\n\n")
	b.WriteString(sandboxPreamble)
	b.WriteString(prompt)
	b.WriteString("\n")
	writeEmbeddedSkills(&b, skillsMap)
	return writeFile(path, []byte(b.String()))
}

// --- Shared: SKILL.md file generation for Claude/Codex/Cursor ---

func generateSkillMDFiles(skillsDir string, skills map[string]*SkillDef) error {
	if skillsDir == "" {
		return nil
	}

	for name, skill := range skills {
		dir := filepath.Join(skillsDir, name)
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("creating skill dir %s: %w", dir, err)
		}

		var b strings.Builder
		writeSkillFrontmatter(&b, skill)
		b.WriteString(skill.Content)
		b.WriteString("\n")

		path := filepath.Join(dir, "SKILL.md")
		if err := os.WriteFile(path, []byte(b.String()), 0644); err != nil {
			return fmt.Errorf("writing %s: %w", path, err)
		}
		log.Printf("[skills] wrote %s", path)
	}

	return nil
}

// --- Helpers ---

// writeEmbeddedSkills appends skills to a prompt file using HTML comment section markers.
// Used by both Codex (AGENTS.md) and Cursor (rules .mdc file).
func writeEmbeddedSkills(b *strings.Builder, skillsMap map[string]*SkillDef) {
	if len(skillsMap) == 0 {
		return
	}
	names := sortedSkillNames(skillsMap)
	for _, name := range names {
		def := skillsMap[name]
		fmt.Fprintf(b, "\n<!-- nanosandbox skill: %s -->\n", name)
		fmt.Fprintf(b, "## %s\n\n", def.Name)
		b.WriteString(def.Content)
		b.WriteString("\n")
	}
}

// writeSkillFrontmatter writes YAML frontmatter for a SKILL.md file,
// including optional fields when non-empty.
func writeSkillFrontmatter(b *strings.Builder, def *SkillDef) {
	b.WriteString("---\n")
	fmt.Fprintf(b, "name: %s\n", def.Name)
	fmt.Fprintf(b, "description: %s\n", def.Description)
	if def.Version != "" {
		fmt.Fprintf(b, "version: %q\n", def.Version)
	}
	if def.WhenToUse != "" {
		fmt.Fprintf(b, "when_to_use: %q\n", def.WhenToUse)
	}
	if len(def.AllowedTools) > 0 {
		b.WriteString("allowed-tools: ")
		b.WriteString(strings.Join(def.AllowedTools, " "))
		b.WriteString("\n")
	}
	if def.UserInvocable != nil && !*def.UserInvocable {
		b.WriteString("user-invocable: false\n")
	}
	if len(def.Paths) > 0 {
		b.WriteString("paths:\n")
		for _, p := range def.Paths {
			fmt.Fprintf(b, "  - %q\n", p)
		}
	}
	b.WriteString("---\n\n")
}

func writeFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("creating dir %s: %w", dir, err)
	}
	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	log.Printf("[skills] wrote %s", path)
	return nil
}

func sortedSkillNames(skills map[string]*SkillDef) []string {
	names := make([]string, 0, len(skills))
	for k := range skills {
		names = append(names, k)
	}
	sort.Strings(names)
	return names
}

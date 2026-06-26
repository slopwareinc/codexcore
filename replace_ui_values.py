import os
import re

directory = "/Users/betterclever/Projects/slopware/CodexCore/Sources/CodexCoreUI"

replacements = [
    # CodexTerminalView.swift
    (r'\.font\(\.system\(\.body, design: \.monospaced\)\)', r'.font(theme.fonts.code)'),
    (r'\.padding\(8\)', r'.padding(theme.spacing.rowGap)'),
    (r'Color\(red: 0\.05, green: 0\.05, blue: 0\.05\)', r'theme.colors.codeBackground'),
    (r'\.withAnimation\(\.easeOut\(duration: 0\.15\)\)', r'.withAnimation(.easeOut(duration: theme.animations.defaultDuration))'),
    (r'withAnimation\(\.easeOut\(duration: 0\.15\)\)', r'withAnimation(.easeOut(duration: theme.animations.defaultDuration))'),
    
    # CodexSubagentRunView.swift
    (r'\.snappy\(duration: 0\.18\)', r'.snappy(duration: theme.animations.snappyDuration)'),
    (r'\.frame\(width: 16, height: 16\)', r'.frame(width: theme.spacing.iconMedium, height: theme.spacing.iconMedium)'),
    (r'\.frame\(width: 13, height: 13\)', r'.frame(width: theme.spacing.iconSmall, height: theme.spacing.iconSmall)'),
    (r'opacity\(0\.64\)', r'opacity(theme.effects.textFaintOpacity)'),
    (r'opacity\(0\.72\)', r'opacity(theme.effects.glassOpacity)'),
    
    # CodexAgentPanels.swift
    (r'\.frame\(width: 16, height: 16\)', r'.frame(width: theme.spacing.iconMedium, height: theme.spacing.iconMedium)'),
    (r'\.frame\(width: 28, height: 28\)', r'.frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)'),
    (r'opacity\(0\.78\)', r'opacity(theme.effects.surfaceOpacity)'),
    (r'opacity\(0\.82\)', r'opacity(theme.effects.textDimOpacity)'),
    (r'opacity\(0\.24\)', r'opacity(theme.effects.glowOpacity)'),
    
    # CodexChatWorkspace.swift
    (r'\.spring\(response: 0\.32, dampingFraction: 0\.9\)', r'.spring(response: theme.animations.springResponse, dampingFraction: theme.animations.springDamping)'),
    (r'opacity\(0\.001\)', r'opacity(0.001)'), # kept as is since it's a hack for hit testing
    (r'opacity\(0\.92\)', r'opacity(theme.effects.surfaceOpacity)'),
    (r'opacity\(0\.6\)', r'opacity(theme.effects.textFaintOpacity)'),
    
    # CodexComposerBar.swift
    (r'opacity\(0\.58\)', r'opacity(theme.effects.textFaintOpacity)'),
    (r'opacity\(0\.84\)', r'opacity(theme.effects.textDimOpacity)'),
    (r'\.snappy\(duration: 0\.2\)', r'.snappy(duration: theme.animations.snappyDuration)'),
    (r'\.frame\(width: 30, height: 30\)', r'.frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)'),
    (r'\.frame\(width: 34, height: 34\)', r'.frame(width: theme.spacing.iconLarge + 4, height: theme.spacing.iconLarge + 4)'),
    (r'\.frame\(width: 18, height: 18\)', r'.frame(width: theme.spacing.iconMedium, height: theme.spacing.iconMedium)'),
]

files_to_check = [
    "CodexTerminalView.swift",
    "CodexSubagentRunView.swift",
    "CodexAgentPanels.swift",
    "CodexChatWorkspace.swift",
    "CodexComposerBar.swift",
    "CodexMessageContentView.swift",
    "CodexNoticeCard.swift",
    "CodexToolCallCard.swift",
    "CodexTranscriptView.swift",
]

for filename in files_to_check:
    filepath = os.path.join(directory, filename)
    if not os.path.exists(filepath):
        continue
    
    with open(filepath, 'r') as f:
        content = f.read()
    
    new_content = content
    for pattern, replacement in replacements:
        new_content = re.sub(pattern, replacement, new_content)
    
    if new_content != content:
        with open(filepath, 'w') as f:
            f.write(new_content)
        print(f"Updated {filename}")
    else:
        print(f"No changes in {filename}")

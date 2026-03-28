const std = @import("std");

/// Generate bash completion script for igrep.
pub fn generateBashCompletions(_: std.mem.Allocator, writer: anytype) !void {
    const bash_completion =
        \\_igrep() {
        \\    local cur prev opts
        \\    COMPREPLY=()
        \\    cur="${COMP_WORDS[COMP_CWORD]}"
        \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\
        \\    # Flags that take an argument
        \\    local args_flags="-e --regexp -A --after-context -B --before-context -C --context -m --max-count -t --type -j --threads --max-depth --color --completions"
        \\
        \\    # If previous word is a flag that takes an argument, complete appropriately
        \\    case "$prev" in
        \\        -e|--regexp)
        \\            # Pattern argument - no completion
        \\            return 0
        \\            ;;
        \\        -A|--after-context|-B|--before-context|-C|--context|-m|--max-count|-j|--threads|--max-depth)
        \\            # Numeric arguments
        \\            COMPREPLY=( $(compgen -W "1 2 3 5 10 20 50 100" -- $cur) )
        \\            return 0
        \\            ;;
        \\        -t|--type)
        \\            # File type filter
        \\            COMPREPLY=( $(compgen -W "c h cpp rs py js ts go java" -- $cur) )
        \\            return 0
        \\            ;;
        \\        --color|--colour)
        \\            COMPREPLY=( $(compgen -W "always never auto" -- $cur) )
        \\            return 0
        \\            ;;
        \\        --completions)
        \\            COMPREPLY=( $(compgen -W "bash zsh fish" -- $cur) )
        \\            return 0
        \\            ;;
        \\        *)
        \\            ;;
        \\    esac
        \\
        \\    # Complete options
        \\    if [[ "$cur" == -* ]]; then
        \\        opts="-e -i -F -v -w -c -l -n --no-line-number -A -B -C -m -t -j --max-depth --color --json --index --index-build --regexp --ignore-case --fixed-strings --invert-match --word-regexp --count --files-with-matches --line-number --after-context --before-context --context --max-count --type --threads --colour --help --version --completions"
        \\        COMPREPLY=( $(compgen -W "$opts" -- $cur) )
        \\        return 0
        \\    fi
        \\
        \\    # Otherwise, complete with filenames/directories
        \\    COMPREPLY=( $(compgen -f -- $cur) )
        \\}
        \\
        \\complete -F _igrep igrep
        \\
    ;
    try writer.writeAll(bash_completion);
}

/// Generate zsh completion script for igrep.
pub fn generateZshCompletions(_: std.mem.Allocator, writer: anytype) !void {
    const zsh_completion =
        \\#compdef igrep
        \\
        \\_igrep() {
        \\    local -a options
        \\    local -a short_options
        \\    local -a long_options
        \\
        \\    short_options=(
        \\        '-e[Use PATTERN as a regex]:pattern:'
        \\        '-i[Case-insensitive search]'
        \\        '-F[Treat pattern as literal string]'
        \\        '-v[Select non-matching lines]'
        \\        '-w[Match whole words only]'
        \\        '-c[Only print match counts per file]'
        \\        '-l[Only print file paths with matches]'
        \\        '-n[Show line numbers (default)]'
        \\        '-A[Show N lines after each match]:number:'
        \\        '-B[Show N lines before each match]:number:'
        \\        '-C[Show N lines before and after each match]:number:'
        \\        '-m[Stop after N matches per file]:number:'
        \\        '-t[Only search files with extension]:extension:(c h cpp rs py js ts go java)'
        \\        '-j[Number of worker threads]:number:'
        \\        '-h[Show help]'
        \\        '-V[Show version]'
        \\    )
        \\
        \\    long_options=(
        \\        '--regexp[Use PATTERN as a regex]:pattern:'
        \\        '--ignore-case[Case-insensitive search]'
        \\        '--fixed-strings[Treat pattern as literal string]'
        \\        '--invert-match[Select non-matching lines]'
        \\        '--word-regexp[Match whole words only]'
        \\        '--count[Only print match counts per file]'
        \\        '--files-with-matches[Only print file paths with matches]'
        \\        '--line-number[Show line numbers]'
        \\        '--no-line-number[Suppress line numbers]'
        \\        '--after-context[Show N lines after each match]:number:'
        \\        '--before-context[Show N lines before each match]:number:'
        \\        '--context[Show N lines before and after each match]:number:'
        \\        '--max-count[Stop after N matches per file]:number:'
        \\        '--type[Only search files with extension]:extension:(c h cpp rs py js ts go java)'
        \\        '--threads[Number of worker threads]:number:'
        \\        '--max-depth[Max directory recursion depth]:number:'
        \\        '--color[Control color output]:(always never auto)'
        \\        '--colour[Control color output]:(always never auto)'
        \\        '--json[Output results as JSON]'
        \\        '--index[Use trigram index for search]'
        \\        '--index-build[Build/rebuild the trigram index without searching]'
        \\        '--help[Show help]'
        \\        '--version[Show version]'
        \\        '--completions[Generate shell completions]:(bash zsh fish)'
        \\    )
        \\
        \\    _arguments -s "$short_options[@]" "$long_options[@]" '*:files:_files'
        \\}
        \\
        \\_igrep
        \\
    ;
    try writer.writeAll(zsh_completion);
}

/// Generate fish completion script for igrep.
pub fn generateFishCompletions(_: std.mem.Allocator, writer: anytype) !void {
    const fish_completion =
        \\# Completion for igrep
        \\
        \\set -l igrep_help "instantGrep — a blazing-fast code search tool"
        \\
        \\# Short options
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s e -l regexp -d "Use PATTERN as a regex"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s i -l ignore-case -d "Case-insensitive search"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s F -l fixed-strings -d "Treat pattern as literal string"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s v -l invert-match -d "Select non-matching lines"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s w -l word-regexp -d "Match whole words only"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s c -l count -d "Only print match counts per file"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s l -l files-with-matches -d "Only print file paths with matches"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s n -l line-number -d "Show line numbers (default)"
        \\
        \\# Flags with arguments
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s A -l after-context -d "Show N lines after each match" -xa "1 2 3 5 10"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s B -l before-context -d "Show N lines before each match" -xa "1 2 3 5 10"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s C -l context -d "Show N lines before and after each match" -xa "1 2 3 5 10"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s m -l max-count -d "Stop after N matches per file" -xa "1 10 50 100"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s t -l type -d "Only search files with extension" -xa "c h cpp rs py js ts go java"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s j -l threads -d "Number of worker threads" -xa "1 2 4 8"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -l max-depth -d "Max directory recursion depth" -xa "1 2 5 10"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -l color -d "Control color output" -xa "always never auto"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -l colour -d "Control color output" -xa "always never auto"
        \\
        \\# Flags without arguments
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -l no-line-number -d "Suppress line numbers"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -l json -d "Output results as JSON"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -l index -d "Use trigram index for search"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -l index-build -d "Build/rebuild the trigram index without searching"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s h -l help -d "Show help"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -s V -l version -d "Show version"
        \\complete -c igrep -n "__fish_seen_subcommand_from igrep" -l completions -d "Generate shell completions" -xa "bash zsh fish"
        \\
    ;
    try writer.writeAll(fish_completion);
}

// Tests
test "bash completion generation" {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(std.testing.allocator);

    try generateBashCompletions(std.testing.allocator, list.writer(std.testing.allocator));
    try std.testing.expect(list.items.len > 0);
}

test "zsh completion generation" {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(std.testing.allocator);

    try generateZshCompletions(std.testing.allocator, list.writer(std.testing.allocator));
    try std.testing.expect(list.items.len > 0);
}

test "fish completion generation" {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(std.testing.allocator);

    try generateFishCompletions(std.testing.allocator, list.writer(std.testing.allocator));
    try std.testing.expect(list.items.len > 0);
}

import Foundation

/// Lowercase, accent-free, dash-separated: "Mi Proyecto Ñandú!" → "mi-proyecto-nandu".
public func slugify(_ text: String) -> String {
    let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    var slug = ""
    var lastWasDash = true
    for scalar in folded.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
            slug.unicodeScalars.append(scalar)
            lastWasDash = false
        } else if !lastWasDash {
            slug.append("-")
            lastWasDash = true
        }
    }
    while slug.hasSuffix("-") { slug.removeLast() }
    return slug
}

/// Finds the GitHub repo a Lovable project most likely syncs with.
///
/// The strongest signal is Lovable's latest commit being the head of a repo's default
/// branch: Lovable and GitHub share SHAs when they're in sync. Otherwise, a single
/// repo whose name matches the project name.
public func matchRepo(projectName: String?, latestCommitSha: String?, repos: [GitHubRepo]) -> RepoLink? {
    if let sha = latestCommitSha, let repo = repos.first(where: { $0.head?.sha == sha }) {
        return RepoLink(fullName: repo.fullName, source: .commit)
    }
    guard let projectName, !slugify(projectName).isEmpty else { return nil }
    let slug = slugify(projectName)
    let byName = repos.filter { !$0.isArchived && slugify($0.name) == slug }
    if byName.count == 1 {
        return RepoLink(fullName: byName[0].fullName, source: .name)
    }
    return nil
}

/// Repos ordered for the "link a repo" menu: closest names first, then most recently pushed.
public func rankRepos(for projectName: String?, repos: [GitHubRepo]) -> [GitHubRepo] {
    let slug = slugify(projectName ?? "")
    let words = Set(slug.split(separator: "-").filter { $0.count > 2 })
    func score(_ repo: GitHubRepo) -> Int {
        let name = slugify(repo.name)
        if name == slug { return 100 }
        if !slug.isEmpty && (name.contains(slug) || slug.contains(name)) { return 50 }
        return Set(name.split(separator: "-")).intersection(words).count * 10
    }
    // `repos` arrives sorted by last push, and sorting is stable on ties.
    return repos.enumerated()
        .sorted { a, b in
            let (sa, sb) = (score(a.element), score(b.element))
            return sa != sb ? sa > sb : a.offset < b.offset
        }
        .map(\.element)
}

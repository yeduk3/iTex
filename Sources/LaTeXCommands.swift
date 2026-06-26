// ponytail: static list. Add texlab LSP (`brew install texlab`) for semantic completions.
enum LaTeXCommands {
    static func completions(for prefix: String) -> [String] {
        let p = prefix.hasPrefix("\\") ? prefix : "\\" + prefix
        return all.filter { $0.hasPrefix(p) }.sorted()
    }

    static let all: [String] = [
        // Structure
        "\\documentclass", "\\usepackage", "\\begin", "\\end",
        "\\section", "\\subsection", "\\subsubsection",
        "\\chapter", "\\paragraph", "\\subparagraph",
        "\\part", "\\appendix", "\\tableofcontents",
        "\\listoffigures", "\\listoftables",
        "\\input", "\\include", "\\includeonly",
        "\\newcommand", "\\renewcommand", "\\providecommand",
        "\\newenvironment", "\\renewenvironment",
        // Text formatting
        "\\textbf", "\\textit", "\\texttt", "\\textsc", "\\textrm",
        "\\textsf", "\\textsl", "\\textup", "\\emph",
        "\\underline", "\\overline",
        "\\tiny", "\\scriptsize", "\\footnotesize", "\\small",
        "\\normalsize", "\\large", "\\Large", "\\LARGE", "\\huge", "\\Huge",
        // Math
        "\\frac", "\\dfrac", "\\tfrac", "\\sqrt", "\\sum",
        "\\int", "\\oint", "\\prod", "\\lim", "\\max", "\\min",
        "\\inf", "\\sup", "\\det", "\\log", "\\ln", "\\sin",
        "\\cos", "\\tan", "\\arcsin", "\\arccos", "\\arctan", "\\exp",
        "\\binom", "\\dbinom", "\\tbinom",
        "\\left", "\\right", "\\cdot", "\\cdots", "\\ldots", "\\vdots", "\\ddots",
        "\\pm", "\\mp", "\\times", "\\div",
        "\\leq", "\\geq", "\\neq", "\\approx", "\\equiv", "\\sim",
        "\\simeq", "\\cong", "\\propto",
        "\\infty", "\\nabla", "\\partial", "\\forall", "\\exists",
        "\\in", "\\notin", "\\subset", "\\supset", "\\subseteq", "\\supseteq",
        "\\cup", "\\cap", "\\emptyset", "\\varnothing", "\\setminus",
        "\\mathbb", "\\mathbf", "\\mathit", "\\mathsf",
        "\\mathtt", "\\mathcal", "\\mathfrak", "\\mathrm",
        "\\hat", "\\tilde", "\\bar", "\\vec", "\\dot", "\\ddot",
        "\\widehat", "\\widetilde", "\\overrightarrow", "\\overleftarrow",
        // Greek letters
        "\\alpha", "\\beta", "\\gamma", "\\delta", "\\epsilon", "\\varepsilon",
        "\\zeta", "\\eta", "\\theta", "\\vartheta", "\\iota", "\\kappa",
        "\\lambda", "\\mu", "\\nu", "\\xi", "\\pi", "\\varpi",
        "\\rho", "\\varrho", "\\sigma", "\\varsigma", "\\tau",
        "\\upsilon", "\\phi", "\\varphi", "\\chi", "\\psi", "\\omega",
        "\\Gamma", "\\Delta", "\\Theta", "\\Lambda", "\\Xi",
        "\\Pi", "\\Sigma", "\\Upsilon", "\\Phi", "\\Psi", "\\Omega",
        // References & citations
        "\\label", "\\ref", "\\eqref", "\\pageref",
        "\\cite", "\\citep", "\\citet", "\\bibitem",
        "\\bibliography", "\\bibliographystyle",
        "\\footnote", "\\footnotemark", "\\footnotetext",
        // Floats
        "\\caption", "\\includegraphics", "\\centering",
        "\\raggedleft", "\\raggedright",
        // Spacing & layout
        "\\hspace", "\\vspace", "\\hfill", "\\vfill",
        "\\noindent", "\\indent", "\\newline", "\\linebreak",
        "\\pagebreak", "\\newpage", "\\clearpage", "\\par",
        "\\medskip", "\\bigskip", "\\smallskip",
        "\\setlength", "\\addtolength", "\\setcounter", "\\addtocounter",
        // Tables
        "\\hline", "\\cline", "\\multicolumn", "\\multirow",
        "\\toprule", "\\midrule", "\\bottomrule",
        // Misc
        "\\item", "\\today", "\\LaTeX", "\\TeX",
        "\\maketitle", "\\title", "\\author", "\\date", "\\and",
        "\\color", "\\textcolor", "\\colorbox", "\\fcolorbox",
        "\\href", "\\url", "\\hyperref",
        "\\verbatim", "\\verb",
    ]
}

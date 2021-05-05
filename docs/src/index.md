````@eval
using Markdown
Markdown.parse("""
$(read(joinpath("..", "..", "README.md"), String))
""")
````
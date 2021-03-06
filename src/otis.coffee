###!
# otis.js

A highly customizable, extremely simple documentation generator based on

- [jashkenas / **docco**](http://jashkenas.github.com/docco/)
- [mbrevoort / **docco-husky**](https://github.com/mbrevoort/docco-husky)
- [jbt / **docker**](http://jbt.github.com/docker)

__otis__ was once a really simple documentation generator -- **docker**.  **docker** originally
started out as a pure-javascript port of **docco**, but eventually gained many extra little features
that somewhat break docco's philosophy of being a quick-and-dirty thing.

__docker__ was based on **docco**'s coffeescript source, but converted to javascript.

__otis__ is based on **docker**, but has been re-converted to coffeescript.

especially given that some of the conversion was made using the fantastic (but not infallible)
(http://js2coffee.org), you might notice some strange code artifacts here and there -- javascript-isms
converted into coffeescript, and coffeescript-isms converted *through* javascript back into itself.

otis source code can be found on GitHub at [brynbellomy / otis](https://github.com/brynbellomy/otis)

By the way, this page is the result of running otis against itself (with some additional custom CSS appended).
###

# module includes
fs            = require "fs"
dox           = require "dox"
path          = require "path"
{exec, spawn} = require "child_process"
watchr        = require "watchr"
mkdirp        = require "mkdirp"
consolidate   = require "consolidate"


class exports.Otis

  ###!
  ## Otis()

  Creates a new otis instance. All methods are called on one instance of this object.

  Input arguments are an object containing any of the keys

  - `inDir`
  - `outDir`
  - `tplDir`,
  - `tplEngine`
  - `tplExtension`
  - `markdownEngine`
  - `colorScheme`
  - `css`
  - `index`
  - `tolerant`
  - `delimStart`
  - `delimEnd`
  - `onlyUpdated`
  - `ignoreHidden`
  - `sidebarState`
  - `exclude`

  @constructor
  @param {object} opts
  ###
  constructor: (opts) ->
    @parseOpts opts
    @running = false
    @scanQueue = []
    @files = []
    @tree = {}


  parseOpts: (opts) =>
    defaults =
      inDir: path.resolve "."
      outDir: path.resolve "doc"
      tplDir: path.join path.resolve(__dirname), "res"
      tplEngine: "internal"
      tplExtension: "jst"
      markdownEngine: "marked"
      colourScheme: "default"
      css: []
      index: null
      tolerant: false
      delimStart: null
      delimEnd: null
      onlyUpdated: false
      ignoreHidden: false
      sidebarState: true
      exclude: false

    
    # Loop through and fix up any unspecified options with the defaults.
    for i of defaults
      do (i) ->
        if defaults.hasOwnProperty(i) and typeof opts[i] is "undefined"
          opts[i] = defaults[i]

    @inDir          = opts.inDir.replace(/\/$/, "")
    @outDir         = opts.outDir
    @tplDir         = opts.tplDir
    @tplEngine      = opts.tplEngine
    @tplExtension   = opts.tplExtension
    @markdownEngine = opts.markdownEngine
    @onlyUpdated    = !!opts.onlyUpdated
    @colourScheme   = opts.colourScheme
    @css            = opts.css
    @index          = opts.index
    @tolerant       = !!opts.tolerant
    @delimStart     = (if opts.delimStart? then RegExp(opts.delimStart) else undefined)
    @delimEnd       = (if opts.delimEnd?   then RegExp(opts.delimEnd)   else undefined)
    @ignoreHidden   = !!opts.ignoreHidden
    @sidebarState   = opts.sidebarState
    
    # Generate an exclude regex for the given pattern
    if typeof opts.exclude is "string"
      @excludePattern = new RegExp("^(" + opts.exclude.replace(/\./g, "\\.").replace(/\*/g, ".*").replace(/,/g, "|") + ")(/|$)")
    else
      @excludePattern = false
    
    # Oh go on then. Allow American-Enligsh spelling of colour if used programmatically
    if opts.colorScheme? then opts.colourScheme = opts.colorScheme

    # setup the markdown renderer fn
    @_renderMarkdown = (text, cb) =>
      fn = null
      switch @markdownEngine
        when "gfm"
          fn = require("github-flavored-markdown").parse
        when "showdown"
          fn = require("#{__dirname}/../res/showdown").Showdown.makeHtml
        when "marked"
          fn = require "marked"
          fn.setOptions {
            gfm: false
            pedantic: false
            sanitize: false
          }
        else
          fn = (data) -> data  # pass-through
      return fn text


  ###!
  ## doc

  Generates documentation for specified files.

  @param {Array} files Array of file paths relative to the `inDir` to generate documentation for.
  ###
  doc: (files) =>
    @running = true
    [].push.apply @scanQueue, files
    @addNextFile()


  ###!
  ## watch

  Watches the input directory for file changes and updates docs whenever a file is updated

  @param {Array} files Array of file paths relative to the `inDir` to generate documentation for.
  ###
  watch: (files) =>
    @watching = true
    @watchFiles = files
    uto = false
    self = this
    
    # Function to call when a file is changed. We put this on a timeout to account
    # for several file changes happening in quick succession.
    update = ->
      return (uto = setTimeout(update, 250))  if self.running
      self.clean()
      self.doc self.watchFiles
      uto = false
    
    # Install watchr. The `null` here is a watchr bug - looks like he forgot to allow for exactly
    # two arguments (like in his example)
    watchr.watch(@inDir, (->
      uto = setTimeout(update, 250)  unless uto
    ), null)
    
    # Aaaaand, go!
    return @doc(files)


  ###!
  ## finished

  Callback function fired when processing is finished.
  ###
  finished: (err) =>
    if err then console.error err.toString().red
    @running = false

    if @watching
      # If we're in watch mode, switch "only updated files" mode on if it isn't already
      @onlyUpdated = true
      console.log "Done. Waiting for changes..."
    else
      console.log "Done."


  ###!
  ## clean

  Clears out any instance variables so this otis can be rerun
  ###
  clean: =>
    @scanQueue = []
    @files = []
    @tree = {}


  ###!
  ## addNextFile

  Process the next file on the scan queue. If it's a directory, list all the children and queue those.
  If it's a file, add it to the queue.
  ###
  addNextFile: =>
    self = this
    if @scanQueue.length > 0
      filename = @scanQueue.shift()

      if @excludePattern and @excludePattern.test(filename)
        return @addNextFile()
      
      currFile = path.resolve(@inDir, filename)

      cb = (err, stat) ->
        if stat?.isSymbolicLink()
          fs.readlink(currFile, (err, link) ->
            currFile = path.resolve(path.dirname(currFile), link)
            fs.exists(currFile, (exists) ->
              if not exists
                console.error "Unable to follow symlink to " + currFile + ": file does not exist"
                self.addNextFile()
              else
                fs.lstat(currFile, cb)
            )
          )
        else if stat?.isDirectory()
          # Find all children of the directory and queue those
          return fs.readdir(path.resolve(self.inDir, filename), (err, list) ->
            for maybe in list
              if self.ignoreHidden and maybe.charAt(0).match(/[\._]/) then continue
              self.scanQueue.push(path.join(filename, maybe))

            return self.addNextFile()
          )
        else
          self.queueFile(filename)
          return self.addNextFile()

      return fs.lstat(currFile, cb)
    else # Once we're done scanning all the files, start processing them in order.
      return @processNextFile()


  ###!
  ## queueFile

  Queues a file for processing, and additionally stores it in the folder tree

  @param {string} filename Name of the file to queue
  ###
  queueFile: (filename) =>
    @files.push filename


  ###!
  ## addFileToTree

  Adds a file to the file tree to show in the sidebar. This used to be in `queueFile` but
  since we're now only deciding whether or not the file can be included at the point of
  reading it, this has to happen later.

  @param {string} filename Name of file to add to the tree
  ###
  addFileToTree: (filename) =>
    pathSeparator = path.join("a", "b").replace(/(^.*a|b.*$)/g, "")
    
    # Split the file's path into the individual directories
    filename = filename.replace(new RegExp("^" + pathSeparator.replace(/([\/\\])/g, "\\$1")), "")
    bits = filename.split(pathSeparator)
    
    # Loop through all the directories and process the folder structure into `this.tree`.
    #
    # `this.tree` takes the format:
    # ```js
    #  {
    #    dirs: {
    #      'child_dir_name': { /* same format as tree */ },
    #      'other_child_name': // etc...
    #    },
    #    files: [
    #      'filename.js',
    #      'filename2.js',
    #      // etc...
    #    ]
    #  }
    # ```
    currDir = @tree
    i = 0

    while i < bits.length - 1
      currDir.dirs = {}  unless currDir.dirs
      currDir.dirs[bits[i]] = {}  unless currDir.dirs[bits[i]]
      currDir = currDir.dirs[bits[i]]
      i += 1
    currDir.files = []  unless currDir.files
    currDir.files.push bits[bits.length - 1]


  ###!
  ## processNextFile

  Take the next file off the queue and process it
  ###
  processNextFile: =>
    # If we still have files on the queue, process the first one
    if @files.length > 0
      @generateDoc @files.shift(), => @processNextFile()
    else
      @copySharedResources()


  ###!
  ## generateDoc

  _This is where the magic happens_

  Generate the documentation for a file

  @param {string} filename File name to generate documentation for
  @param {function} cb Callback function to execute when we're done
  ###
  generateDoc: (infilename, cb) =>
    @running = true
    filename = path.resolve(@inDir, infilename)

    @decideWhetherToProcess(filename, (shouldProcess) =>
      if not shouldProcess then return cb()

      fs.readFile(filename, "utf-8", (err, data) =>
        if err then throw err

        lang = @languageParams(filename, data)
        if lang is false then return cb()

        @addFileToTree infilename

        switch @languages[lang].type
          when "markdown"
            @renderMarkdownHtml data, filename, cb
          when "code"
          else
            sections = @parseSections data, lang
            @highlight sections, lang, =>
              @renderCodeHtml sections, filename, cb
      )
    )

  ###!
  ## decideWhetherToProcess

  Decide whether or not a file should be processed. If the `onlyUpdated`
  flag was set on initialization, only allow processing of files that
  are newer than their counterpart generated doc file.

  Fires a callback function with either true or false depending on whether
  or not the file should be processed

  @param {string} filename The name of the file to check
  @param {function} callback Callback function
  ###
  decideWhetherToProcess: (filename, callback) =>
    # If we should be processing all files, then yes, we should process this one
    if not @onlyUpdated
      return callback(true)
    
    # Find the doc this file would be compiled to
    outFile = @outFile(filename)
    
    # See whether the file is newer than the output
    @fileIsNewer filename, outFile, callback


  ###!
  ## fileIsNewer

  Sees whether one file is newer than another

  @param {string} file File to check
  @param {string} otherFile File to compare to
  @param {function} callback Callback to fire with true if file is newer than otherFile
  ###
  fileIsNewer: (file, otherFile, callback) =>
    fs.stat otherFile, (err, outStat) ->
      
      # If the output file doesn't exist, then definitely process this file
      if err and err.code is "ENOENT" then return callback true

      fs.stat file, (err, inStat) ->
        # Process the file if the input is newer than the output
        callback +inStat.mtime > +outStat.mtime




  ###!
  ## parseSections

  Parse the content of a file into individual sections.
  A section is defined to be one block of code with an accompanying comment

  Returns an array of section objects, which take the form
  ```js
  {
  doc_text: 'foo', // String containing comment content
  code_text: 'bar' // Accompanying code
  }
  ```
  @param {string} data The contents of the script file
  @param {string} language The language of the script file

  @return {Array} array of section objects
  ###
  parseSections: (data, language) =>
    
    # Fetch language-specific parameters for this code file
    md = (a, stripParas) =>
      h = @_renderMarkdown a.replace /(^\s*|\s*$)/, ""
      return (if stripParas then h.replace(/<\/?p>/g, "") else h)

    codeLines = data.split("\n")
    sections = []
    params = @languages[language]

    multilineDelims =
      start: @delimStart ? (params?.multiLine?[0] ? null)
      end:   @delimEnd   ? (params?.multiLine?[1] ? null)

    section =
      docs: ""
      code: ""

    inMultiLineComment = false
    numSpacesIndent = 0
    multiLine = ""
    doxData = undefined
    commentRegex = new RegExp("^\\s*" + params.comment + "\\s?")
    
    # Loop through all the lines, and parse into sections
    async = require "async"
    async.forEachSeries codeLines, (line, forEachCb) =>
      
      # Only match against parts of the line that don't appear in strings
      matchable = line.replace(/(["'])(?:\\.|(?!\1).)*\1/g, "")
      if multilineDelims.start? and multilineDelims.end?
        
        # If we are currently in a multiline comment, behave differently
        if inMultiLineComment
          
          # End-multiline comments should match regardless of whether they're 'quoted'
          if line.match(multilineDelims.end)
            
            # Once we have reached the end of the multiline, take the whole content
            # of the multiline comment, and pass it through **dox**, which will then
            # extract any **jsDoc** parameters that are present.
            inMultiLineComment = false
            if params.dox 
              multiLine += line
              try
                
                # Slightly-hacky-but-hey-it-works way of persuading Dox to work with
                # non-javascript comments by [brynbellomy](https://github.com/brynbellomy)
                
                # standardize the comment block delimiters to the only ones that
                # dox seems to understand, namely, /* and */
                multiLine = multiLine.replace(multilineDelims.start, "").replace(multilineDelims.end, "") #.replace(/\n (?:[^\*])/g, "\n")
                if multiLine.charAt(0) is "!" then multiLine = multiLine.slice 1 # remove our strict-mode comment marker
                multiLine = "/**#{multiLine}*/"
                                .split('\n')
                                .map((line) -> return line.replace(new RegExp("^ {#{numSpacesIndent}}"), ''))
                                .join('\n')

                doxData = dox.parseComments(multiLine, raw: yes)[0]
                
                
                # Don't let dox do any markdown parsing. We'll do that all ourselves with md above
                doxData.md = md
                return @render "dox", doxData, (err, rendered) =>
                  if err then throw err
                  section.docs += rendered
                  forEachCb()

              catch e
                console.error "Dox error: " + e
                multiLine += line.replace(multilineDelims.end, "") + "\n"
                section.docs += "\n" + multiLine.replace(multilineDelims.start, "") + "\n"
            else
              multiLine += line.replace(multilineDelims.end, "") + "\n"
              section.docs += "\n" + multiLine.replace(multilineDelims.start, "") + "\n"
            multiLine = ""
          else
            multiLine += line + "\n"

          return forEachCb()
        
        # We want to match the start of a multiline comment only if the line doesn't also match the
        # end of the same comment, or if a single-line comment is started before the multiline
        # So for example the following would not be treated as a multiline starter:
        # ```js
        #  alert('foo'); // Alert some foo /* Random open comment thing
        # ```
        else if (@tolerant is yes or matchable.replace(/\s*/, "").replace(multilineDelims.start, "").charAt(0) is "!") and matchable.match(multilineDelims.start) and not matchable.replace(multilineDelims.start, "").match(multilineDelims.end) and not matchable.split(multilineDelims.start)[0].match(commentRegex)
          # Here we start parsing a multiline comment. Store away the current section and start a new one
          if section.code
            if not section.code.match(/^\s*$/) or not section.docs.match(/^\s*$/)
              sections.push section

            section =
              docs: ""
              code: ""

          match = matchable.match(multilineDelims.start)
          if match[1]
            numSpacesIndent = match[1].length
          inMultiLineComment = true
          multiLine = line + "\n"

          return forEachCb()

      if matchable.match(commentRegex) and (not params.commentsIgnore or not matchable.match(params.commentsIgnore)) and not matchable.match(/#!/) and (@tolerant is yes or matchable.replace(commentRegex, "").charAt(0) is "!")
        # This is for single-line comments. Again, store away the last section and start a new one
        if section.code
          if not section.code.match(/^\s*$/) or not section.docs.match(/^\s*$/) then sections.push(section)

          section =
            docs: ""
            code: ""

        line = line.replace(commentRegex, "")
        if line.charAt(0) is "!" then line = line.slice 1 # remove ! from beginning of comment if we're running in strict mode
        section.docs += line + "\n"

      else
        if not params.commentsIgnore or not line.match(params.commentsIgnore) then section.code += line + "\n"

      return forEachCb()

    sections.push section
    sections


  ###!
  ## languageParams

  Provides language-specific params for a given file name.

  @param {string} filename The name of the file to test
  @param {string} filedata The contents of the file (to check for shebang)
  @return {object} Object containing all of the language-specific params
  ###
  languageParams: (filename, filedata) =>
    
    # First try to detect the language from the file extension
    ext = path.extname(filename)
    ext = ext.replace(/^\./, "")
    
    # Bit of a hacky way of incorporating .C for C++
    return "cpp"  if ext is ".C"
    ext = ext.toLowerCase()
    for i of @languages
      continue  unless @languages.hasOwnProperty(i)
      return i  if @languages[i].extensions.indexOf(ext) isnt -1
    
    # If that doesn't work, see if we can grab a shebang
    shebangRegex = /^\n*#!\s*(?:\/usr\/bin\/env)?\s*(?:[^\n]*\/)*([^\/\n]+)(?:\n|$)/
    match = shebangRegex.exec(filedata)
    if match
      for j of @languages
        continue  unless @languages.hasOwnProperty(j)
        return j  if @languages[j].executables and @languages[j].executables.indexOf(match[1]) isnt -1
    
    # If we still can't figure it out, give up and return false.
    false


  ###!
  The language params can have the following keys:
  
  + `name`: Name of Pygments lexer to use
  + `comment`: String flag for single-line comments
  + `multiline`: Two-element array of start and end flags for block comments
  + `commentsIgnore`: Regex of comments to strip completely (don't even doc)
  + `dox`: Whether to run block comments through Dox
  + `type`: Either `'code'` (default) or `'markdown'` - format of page to render
  ###
  languages:
    javascript:
      extensions: ["js"]
      executables: ["node"]
      comment: "//"
      multiLine: [/\/\*\*?/, /\*\//]
      commentsIgnore: /^\s*\/\/=/
      dox: true

    coffeescript:
      extensions: ["coffee"]
      executables: ["coffee"]
      comment: "#"
      multiLine: [/^(\s*)###/, /###\s*$/]
      # multiLine: [/^###\s*!?\s*$/m, /^###\s*$/m]
      dox: true

    ruby:
      extensions: ["rb"]
      executables: ["ruby"]
      comment: "#"
      multiLine: [/\=begin/, /\=end/]

    python:
      extensions: ["py"]
      executables: ["python"]
      comment: "#" # Python has no block commments :-(

    perl:
      extensions: ["pl", "pm"]
      executables: ["perl"]
      comment: "#" # Nor (really) does perl.

    c:
      extensions: ["c"]
      executables: ["gcc"]
      comment: "//"
      multiLine: [/\/\*/, /\*\//]

    objc:
      extensions: ["m", "h"]
      executables: ["clang", "gcc"]
      dox: true
      comment: "//"
      multiLine: [/\/\*\*?/, /\*\//]

    cpp:
      extensions: ["cc", "cpp"]
      executables: ["g++"]
      comment: "//"
      multiLine: [/\/\*/, /\*\//]

    csharp:
      extensions: ["cs"]
      comment: "//"
      multiLine: [/\/\*/, /\*\//]

    java:
      extensions: ["java"]
      comment: "//"
      multiLine: [/\/\*/, /\*\//]
      dox: true

    php:
      extensions: ["php", "php3", "php4", "php5"]
      executables: ["php"]
      comment: "//"
      multiLine: [/\/\*/, /\*\//]
      dox: true

    actionscript:
      extensions: ["as"]
      comment: "//"
      multiLine: [/\/\*/, /\*\//]

    sh:
      extensions: ["sh"]
      executables: ["bash", "sh", "zsh"]
      comment: "#"

    yaml:
      extensions: ["yaml", "yml"]
      comment: "#"

    markdown:
      extensions: ["md", "mkd", "markdown"]
      type: "markdown"


  ###!
  ## pygments

  Runs a given block of code through pygments

  @param {string} data The code to give to Pygments
  @param {string} language The name of the Pygments lexer to use
  @param {function} cb Callback to fire with Pygments output
  ###
  pygments: (data, language, cb) =>
    
    # By default tell Pygments to guess the language, and if
    # we have a language specified then tell pygments to use that lexer
    pygArgs = ["-g"]
    pygArgs = ["-l", language]  if language
    
    # Spawn a new **pygments** process
    pyg = spawn "pygmentize", pygArgs.concat(["-f", "html", "-O", "encoding=utf-8,tabsize=2"])
    
    # Hook up errors, for either when pygments itself throws an error,
    # or for when we're unable to send the code to pygments for some reason
    pyg.stderr.on "data", (err) -> console.error err.toString()

    pyg.stdin.on "error", (err) ->
      console.error "Unable to write to Pygments stdin: ", err
      process.exit 1

    out = ""
    pyg.stdout.on "data", (data) -> out += data.toString()

    # When pygments is done, fire the callback with our output
    pyg.on "exit", -> cb out

    # Feed pygments with the code
    if pyg.stdin.writable
      pyg.stdin.write data
      pyg.stdin.end()


  ###!
  ## highlight

  Highlights all the sections of a file using **pygments**
  Given an array of section objects, loop through them, and for each
  section generate pretty html for the comments and the code, and put them in
  `docHtml` and `codeHtml` respectively

  @param {Array} sections Array of section objects
  @param {string} language Language ith which to highlight the file
  @param {function} cb Callback function to fire when we're done
  ###
  highlight: (sections, language, cb) =>
    params = @languages[language]
    input = []
    i = 0

    while i < sections.length
      input.push sections[i].code
      i += 1
    input = input.join("\n" + params.comment + "----{DIVIDER_THING}----\n")
    
    # Run our input through pygments, then split the output back up into its constituent sections
    @pygments input, language, (out) =>
      out = out.replace(/^\s*<div class="highlight"><pre>/, "").replace(/<\/pre><\/div>\s*$/, "")
      bits = out.split(new RegExp("\\n*<span class=\"c[1p]?\">" + params.comment + "----\\{DIVIDER_THING\\}----<\\/span>\\n*"))
      i = 0

      for section, i in sections
        section.codeHtml = "<div class=\"highlight\"><pre>" + bits[i] + "</pre></div>"
        section.docHtml = @_renderMarkdown section.docs
        i += 1
      @processDocCodeBlocks sections, cb



  ###!
  ## processDocCodeBlocks

  Goes through all the HTML generated from comments, finds any code blocks
  and highlights them

  @param {Array} sections Sections array as above
  @param {function} cb Callback to fire when done
  ###
  processDocCodeBlocks: (sections, cb) =>
    self = this
    i = 0

    next = ->
      # If we've reached the end of the sections array, we've highlighted everything,
      # so we can stop and fire the callback
      if i is sections.length
        return cb()
      
      # Process the code blocks on this section, each time returning the html
      # and moving onto the next section when we're done
      return self.extractDocCode( sections[i].docHtml, (html) ->
        sections[i].docHtml = html
        i = i + 1
        return next()
      )

    
    # Start off with the first section
    next()


  ###!
  ## extractDocCode

  Extract and highlight code blocks in formatted HTML output from showdown

  @param {string} html The HTML to process
  @param {function} cb Callback function to fire when done
  ###
  extractDocCode: (html, cb) =>
    
    # We'll store all extracted code blocks, along with information, in this array
    codeBlocks = []
    
    # Search in the HTML for any code tag with a language set (in the format that showdown returns)
    html = html.replace(/<pre><code(\slanguage='([a-z]*)')?>([^<]*)<\/code><\/pre>/g, (wholeMatch, langBlock, language, block) ->
      if langBlock is "" or language is ""
        return "<div class='highlight'>" + wholeMatch + "</div>"
      
      # Unescape these HTML entities because they'll be re-escaped by pygments
      block = block.replace(/&gt;/g, ">").replace(/&lt;/g, "<").replace(/&amp;/, "&")
      
      # Store the code block away in `codeBlocks` and leave a flag in the original text.
      return ("\n\n~C" + codeBlocks.push({
        language: language
        code: block
        i: codeBlocks.length + 1
      }) + "C\n\n")
    )
    
    # Once we're done with that, now we can move on to highlighting the code we've extracted
    return @highlightExtractedCode(html, codeBlocks, cb)


  ###!
  ## highlightExtractedCode

  Loops through all extracted code blocks and feeds them through pygments
  for code highlighting. Unfortunately the only way to do this that's able
  to cater for all situations is to spawn a new pygments process for each
  code block (as different blocks might be in different languages). If anyone
  knows of a more efficient way of doing this, please let me know.

  @param {string} html The HTML the code has been extracted from
  @param {Array} codeBlocks Array of extracted code blocks as above
  @param {function} cb Callback to fire when we're done with processed HTML
  ###
  highlightExtractedCode: (html, codeBlocks, cb) =>
    self = this

    next = ->
      
      # If we're done, then stop and fire the callback
      if codeBlocks.length is 0
        return cb(html)
      
      # Pull the next code block off the beginning of the array
      nextBlock = codeBlocks.shift()
      
      # Run the code through pygments
      self.pygments( nextBlock.code, nextBlock.language, (out) ->
        out = out.replace(/<pre>/, "<pre><code>").replace(/<\/pre>/, "</code></pre>")
        html = html.replace("\n~C" + nextBlock.i + "C\n", out)
        next()
      )
    
    # Fire off on first block
    next()


  ###!
  ## addAnchors

  Automatically assign an id to each section based on any headings.

  @param {object} section The section object to look at
  @param {number} idx The index of the section in the whole array.
  ###
  addAnchors: (docHtml, idx, headings) =>
    if docHtml.match(/<h[0-9]>/)
      
      # If there is a heading tag, pick out the first one (likely the most important), sanitize
      # the name a bit to make it more friendly for IDs, then use that
      docHtml = docHtml.replace(/(<h([0-9])>)(.*)(<\/h\2>)/g, (a, start, level, middle, end) ->
        id = middle.replace(/<[^>]*>/g, "").toLowerCase().replace(/[^a-zA-Z0-9\_\.]/g, "-")
        headings.push({
          id: id
          text: middle.replace(/<[^>]*>/g, "")
          level: level
        })
        return "\n<div class=\"pilwrap\" id=\"" + id + "\">\n  " + start + "\n    <a href=\"#" + id + "\" class=\"pilcrow\">&#182;</a>\n    " + middle + "\n  " + end + "\n</div>\n"
      )
    else # If however we can't find a heading, then just use the section index instead.
      docHtml = "\n<div class=\"pilwrap\">" + "\n  <a class=\"pilcrow\" href=\"#section-" + (idx + 1) + "\" id=\"section-" + (idx + 1) + "\">&#182;</a>" + "\n</div>\n" + docHtml

    return docHtml


  ###!
  ## renderCodeHtml

  Given an array of sections, render them all out to a nice HTML file

  @param {Array} sections Array of sections containing parsed data
  @param {string} filename Name of the file being processed
  @param {function} cb Callback function to fire when we're done
  ###
  renderCodeHtml: (sections, filename, cb) =>
    
    self = this

    # Decide which path to store the output on.
    outFile = @outFile(filename)
    headings = []
    
    # Calculate the location of the input root relative to the output file.
    # This is necessary so we can link to the stylesheet in the output HTML using
    # a relative href rather than an absolute one
    outDir = path.dirname(outFile)
    pathSeparator = path.join("a", "b").replace(/(^.*a|b.*$)/g, "")
    relativeOut = path.resolve(outDir).replace(path.resolve(@outDir), "").replace(/^[\/\\]/, "")
    levels = (if relativeOut is "" then 0 else relativeOut.split(pathSeparator).length)
    relDir = Array(levels + 1).join("../")

    i = 0
    for section in sections
      section.docHtml = @addAnchors(section.docHtml, i, headings)
      i++
    
    @render "code", { title: path.basename(filename), sections: sections }, (err, renderedCode) =>
      if err then throw err

      locals = {
        title: path.basename(filename)
        relativeDir: relDir
        content: renderedCode
        headings: headings
        sidebar: @sidebarState
        colourScheme: @colourScheme
        filename: filename.replace(@inDir, "").replace(/^[\/\\]/, "")
      }

      @render "tmpl", locals, (err, rendered) =>
        if err then throw err
        @writeFile outFile, rendered, "Generated: #{outFile.replace(@outDir, '')}", cb


  ###!
  ## renderMarkdownHtml

  Renders the output for a Markdown file into HTML

  @param {string} content The markdown file content
  @param {string} filename Name of the file being processed
  @param {function} cb Callback function to fire when we're done
  ###
  renderMarkdownHtml: (content, filename, cb) =>

    # Run the markdown through *showdown*
    content = @_renderMarkdown content
    
    # Add anchors to all headings
    
    # Wrap up with necessary classes
    
    # Decide which path to store the output on.
    
    # Calculate the location of the input root relative to the output file.
    # This is necessary so we can link to the stylesheet in the output HTML using
    # a relative href rather than an absolute one
    
    # Render the html file using our template
    
    # Recursively create the output directory, clean out any old version of the
    # output file, then save our new file.
    @extractDocCode(content, (content) =>
      headings = []
      content = "<div class=\"docs markdown\">#{ @addAnchors(content, 0, headings) }</div>"
      outFile = @outFile(filename)
      outDir = path.dirname(outFile)
      pathSeparator = path.join("a", "b").replace(/(^.*a|b.*$)/g, "")
      relativeOut = path.resolve(outDir).replace(path.resolve(@outDir), "").replace(/^[\/\\]/, "")
      levels = (if relativeOut is "" then 0 else relativeOut.split(pathSeparator).length)
      relDir = Array(levels + 1).join("../")

      locals = {
        title: path.basename(filename)
        relativeDir: relDir
        content: content
        headings: headings
        colourScheme: @colourScheme
        sidebar: @sidebarState
        filename: filename.replace(@inDir, "").replace(/^[\\\/]/, "")
      }

      @render "tmpl", locals, (err, rendered) =>
        @writeFile outFile, rendered, "Generated: " + outFile.replace(@outDir, ""), cb

    ) #.bind(this)


  ###!
  ## copySharedResources

  Copies the shared CSS and JS files to the output directories
  ###
  copySharedResources: =>

    inPath_scriptJS       = path.join path.dirname(__filename), "..", "res", "script.js"
    inPath_colorSchemeCSS = path.join path.dirname(__filename), "..", "res", "css", "#{@colourScheme}.css"
    outPath_docScriptJS   = path.join @outDir, "doc-script.js"
    outPath_filelistJS    = path.join @outDir, "doc-filelist.js"
    outPath_CSS           = path.join @outDir, "doc-style.css"
    outPath_indexHTML     = path.join @outDir, "index.html"

    log = (msg, cb) =>
      console.log msg
      cb null

    async = require "async"
    async.auto {
      readScriptJS:       (cb, results) => fs.readFile inPath_scriptJS, cb
      readColorschemeCSS: (cb, results) => fs.readFile inPath_colorSchemeCSS, cb
      genPygmentsCSS:     (cb, results) => exec "pygmentize -S #{@colourScheme} -f html -a 'body .highlight'", (code, stdout, stderr) => cb stderr, stdout
      readUserCSS:        (cb, results) => async.map @css, ((file, mapCb) => fs.readFile(path.resolve(file), mapCb)), cb

      renderIndexPage:     (cb, results) => if @index? then @render("index.html", { destination: @index.toString() }, cb) else cb null

      writeIndexPage:     [ "renderIndexPage"
        (cb, results) => if @index? then @writeFileIfDifferent(outPath_indexHTML, results.renderIndexPage, cb) else cb null ]

      writeFilelistJS:    (cb, results) =>
        @writeFileIfDifferent outPath_filelistJS, "var tree=#{ JSON.stringify @tree };", => log "Saved file tree to doc-filelist.js", => cb null

      writeScriptJS:      [ "readScriptJS",
        (cb, results) => @writeFileIfDifferent outPath_docScriptJS, results.readScriptJS, => log "Copied JS to doc-script.js", => cb null ]

      concatCSS:          [ "readColorschemeCSS", "genPygmentsCSS", "readUserCSS",
        (cb, results) => cb null, results.readColorschemeCSS.toString() + results.genPygmentsCSS.toString() + results.readUserCSS.join "\n" ]

      writeAllCSS:        [ "concatCSS"
        (cb, results) => @writeFileIfDifferent outPath_CSS, results.concatCSS, => log "Copied all CSS to doc-style.css", => cb null ]


    }, @finished


  outFile: (filename) =>
    path.normalize filename.replace(path.resolve(@inDir), @outDir) + ".html"


  render: (tplName, locals, cb) =>
    templatePath = path.join @tplDir, "#{tplName}.#{@tplExtension}"

    if @tplEngine is "internal"
      tplFn = @compileTemplate fs.readFileSync(templatePath).toString()
      rendered = tplFn locals
      cb null, rendered
    else
      consolidate[ @tplEngine ](templatePath, locals, cb)


  compileTemplate: (str) =>
    new Function("obj",
                 "var p=[],print=function(){p.push.apply(p,arguments);};" +
                 "with(obj){p.push('" +
                  str.replace(/[\r\t]/g, " ").replace(/(>)\s*\n+(\s*<)/g, "$1\n$2").replace(/(?=<%[^=][^%]*)%>\s*\n*\s*<%(?=[^=])/g, "").replace(/%>\s*(?=\n)/g, "%>").replace(/(?=\n)\s*<%/g, "<%").replace(/\n/g, "~K").replace(/~K(?=[^%]*%>)/g, " ").replace(/~K/g, "\\n").replace(/'(?=[^%]*%>)/g, "\t").split("'").join("\\'").split("\t").join("'").replace(/<%=(.+?)%>/g, "',$1,'").split("<%").join("');").split("%>").join("p.push('") +
                  "');}return p.join('');")

  writeFile: (filename, fileContent, doneLog, doneCallback) ->
    outDir = path.dirname filename
    mkdirp outDir, () ->
      fs.unlink filename, () ->
        fs.writeFile filename, fileContent, () ->
          if doneLog then console.log doneLog
          if doneCallback then doneCallback()


  writeFileIfDifferent: (filename, fileContent, callback) ->
    outDir = path.dirname(filename)
    fs.readFile filename, (err, content) ->
      # file exists and hasn't changed
      if not err and content.toString() is fileContent.toString() then callback?()
      # file has changed
      else mkdirp outDir, -> fs.unlink filename, -> fs.writeFile filename, fileContent, callback




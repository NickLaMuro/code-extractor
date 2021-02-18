require 'yaml'
require 'fileutils'

# Class to extract files and folders from a git repository, while maintaining
# The git history.
module CodeExtractor
  def run
    Runner.new.extract
  end
  module_function :run

  class Config
    def initialize(config_file = 'extractions.yml')
      @config = YAML.load_file(config_file)

      @config[:upstream_branch] ||= "master"

      validate!
    end

    def [](key)
      @config[key]
    end

    def inspect
      @config.inspect
    end
    alias to_s inspect

    def validate!
      missing = %i[name upstream upstream_name extractions].reject { |k| @config[k] }
      raise ArgumentError, "#{missing.map(&:inspect).join(", ")} key(s) missing" if missing.any?
    end
  end

  class GitProject
    attr_reader :name, :url, :git_dir, :new_branch, :source_branch

    def initialize name, url = nil
      @name   = name
      @url    = url
    end

    def init
      @git_dir ||= name

      FileUtils.rm_rf git_dir if Dir.exist?(git_dir)

      puts 'Initializing git dir…'
      system "git init -b master #{git_dir}"
    end

    def clone_to destination, origin_name = "upstream"
      @git_dir ||= destination

      if Dir.exist?(git_dir)
        raise "Not a git dir!" unless system "git -C #{git_dir} status"
      else
        puts 'Cloning…'
        system "git clone --origin #{origin_name} #{url} #{git_dir}"
      end
    end

    def extract_branch source_branch, new_branch, extractions
      puts 'Extracting Branch…'
      @new_branch    = new_branch
      @source_branch = source_branch
      Dir.chdir git_dir do
        `git checkout #{source_branch}`
        `git fetch upstream && git rebase upstream/master`
        if system("git branch | grep #{new_branch}")
          `git branch -D #{new_branch}`
        end
        `git checkout -b #{new_branch}`
        `git rm -r #{extractions}`
        `git commit -m "Extract #{name}"`
      end
    end

    def remove_remote
      Dir.chdir git_dir do
        `git remote rm upstream`
      end
    end

    def remove_tags
      puts 'removing tags'
      Dir.chdir git_dir do
        tags = `git tag`
        tags.split.each do |tag|
          puts "Removing tag #{tag}"
          `git tag -d #{tag}`
        end
      end
    end

    def filter_repo extractions, source_project
      code_extraction_args = %W[
        --source          #{source_project.git_dir}
        --target          #{git_dir}
        --refs            #{source_project.source_branch}
        --commit-callback #{commit_callback source_project.name}
      ]

      extractions.each { |path| code_extraction_args << "--path" << path }

      repo_filter_args = git_filter_repo.FilteringOptions.parse_args(code_extraction_args)
      filter           = git_filter_repo.RepoFilter.new(repo_filter_args)

      puts "running filter..."
      filter.run
    rescue PyCall::PyError => py_err
      exit if py_err.type.to_s == "<class ='SystemExit'>"
      raise
    end

    def commit_callback upstream_name
      text = "transferred from #{upstream_name}@"
      'commit.message = commit.message + b"\n\n(' + text + '"+ commit.original_id + b")"'
    end

    def git_filter_repo
      return @git_filter_repo if defined?(@git_filter_repo)

      require 'pycall/import'

      unless PyCall.sys.path[-1].include?("git-filter-repo")
        PyCall.sys.path.append(File.join(__dir__, "git-filter-repo"))
        @git_filter_repo = PyCall.import_module :git_filter_repo
      end
    end
  end

  class Runner
    def initialize config = nil
      @config         = config || Config.new
      @source_project = GitProject.new @config[:upstream_name], @config[:upstream]
      @target_project = GitProject.new @config[:name], @config[:upstream]
    end

    def extract
      puts @config
      @target_project.init
      @source_project.clone_to upstream_dirname
      @source_project.extract_branch upstream_branch, "extract_#{@config[:name]}", extraction_list
      @target_project.filter_repo extractions, @source_project
    end

    private

    def extraction_list
      @config[:extractions].join(' ')
    end

    def extractions
      @config[:extractions]
    end

    def upstream_branch
      @config[:upstream_branch]
    end

    def upstream_dirname
      "#{@config[:upstream_name].split("/").last}_source"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  CodeExtractor.run
end

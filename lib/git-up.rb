require 'colored'
require 'grit'

class GitUp
  def run
    command = ['git', 'fetch', '--multiple']
    command << '--prune' if prune?
    command += config("fetch.all") ? ['--all'] : remotes

    # puts command.join(" ") # TODO: implement a 'debug' config option
    system(*command)
    raise GitError, "`git fetch` failed" unless $? == 0
    @remote_map = nil # flush cache after fetch

    Grit::Git.with_timeout(0) do
      with_stash do
        returning_to_current_branch do
          rebase_all_branches
        end
      end
    end

    check_bundler
  rescue GitError => e
    puts e.message
    exit 1
  end

  def rebase_all_branches
    col_width = branches.map { |b| b.name.length }.max + 1

    if config("sort")
      branches.sort_by! { |b| b.name }
    end

    branches.each do |branch|
      remote = remote_map[branch.name]

      print branch.name.ljust(col_width)

      if remote.commit.sha == branch.commit.sha
        puts "up to date".green
        next
      end

      base = merge_base(branch.name, remote.name)

      if base == remote.commit.sha
        puts "ahead of upstream".green
        next
      end

      if base == branch.commit.sha
        puts "fast-forwarding...".yellow
      else
        puts "rebasing...".yellow
      end

      log(branch, remote)
      checkout(branch.name)
      rebase(remote)
    end
  end

  def repo
    @repo ||= get_repo
  end

  def get_repo
    repo_dir = `git rev-parse --show-toplevel`.chomp

    if $? == 0
      Dir.chdir repo_dir
      @repo = Grit::Repo.new(repo_dir)
    else
      raise GitError, "We don't seem to be in a git repository."
    end
  end

  def branches
    @branches ||= repo.branches.select { |b| remote_map.has_key?(b.name) }
  end

  def remotes
    @remotes ||= remote_map.values.map { |r| r.name.split('/', 2).first }.uniq
  end

  def remote_map
    @remote_map ||= repo.branches.inject({}) { |map, branch|
      if remote = remote_for_branch(branch)
        map[branch.name] = remote
      end

      map
    }
  end

  def remote_for_branch(branch)
    remote_name   = repo.config["branch.#{branch.name}.remote"] || "origin"
    remote_branch = repo.config["branch.#{branch.name}.merge"] || branch.name
    remote_branch.sub!(%r{^refs/heads/}, '')
    repo.remotes.find { |r| r.name == "#{remote_name}/#{remote_branch}" }
  end

  def with_stash
    stashed = false

    if change_count > 0
      puts "stashing #{change_count} changes".magenta
      repo.git.stash
      stashed = true
    end

    yield

    if stashed
      puts "unstashing".magenta
      repo.git.stash({}, "pop")
    end
  end

  def returning_to_current_branch
    unless repo.head.respond_to?(:name)
      puts "You're not currently on a branch. I'm exiting in case you're in the middle of something.".red
      return
    end

    branch_name = repo.head.name

    yield

    unless on_branch?(branch_name)
      puts "returning to #{branch_name}".magenta
      checkout(branch_name)
    end
  end

  def checkout(branch_name)
    output = repo.git.checkout({}, branch_name)

    unless on_branch?(branch_name)
      raise GitError.new("Failed to checkout #{branch_name}", output)
    end
  end

  def log(branch, remote)
    if log_hook = config("log-hook")
      system('sh', '-c', log_hook, 'git-up', branch.name, remote.name)
    end
  end

  def rebase(target_branch)
    current_branch = repo.head

    output, err = repo.git.sh("#{Grit::Git.git_binary} rebase #{target_branch.name}")

    unless on_branch?(current_branch.name) and is_fast_forward?(current_branch, target_branch)
      raise GitError.new("Failed to rebase #{current_branch.name} onto #{target_branch.name}", output+err)
    end
  end

  def check_bundler
    return unless use_bundler?

    begin
      require 'bundler'
      ENV['BUNDLE_GEMFILE'] ||= File.expand_path('Gemfile')
      Gem.loaded_specs.clear
      Bundler.setup
    rescue Bundler::GemNotFound, Bundler::GitError
      puts
      print 'Gems are missing. '.yellow

      if config("bundler.autoinstall") == 'true'
        puts "Running `bundle install`.".yellow
        system "bundle", "install"
      else
        puts "You should `bundle install`.".yellow
      end
    end
  end

  def is_fast_forward?(a, b)
    merge_base(a.name, b.name) == b.commit.sha
  end

  def merge_base(a, b)
    repo.git.send("merge-base", {}, a, b).strip
  end

  def on_branch?(branch_name=nil)
    repo.head.respond_to?(:name) and repo.head.name == branch_name
  end

  class GitError < StandardError
    def initialize(message, output=nil)
      @msg = "#{message.red}"

      if output
        @msg << "\n"
        @msg << "Here's what Git said:".red
        @msg << "\n"
        @msg << output
      end
    end

    def message
      @msg
    end
  end

private

  def use_bundler?
    use_bundler_config? and File.exists? 'Gemfile'
  end

  def use_bundler_config?
    if ENV.has_key?('GIT_UP_BUNDLER_CHECK')
      puts <<-EOS.yellow
The GIT_UP_BUNDLER_CHECK environment variable is deprecated.
You can now tell git-up to check (or not check) for missing
gems on a per-project basis using git's config system. To
set it globally, run this command anywhere:

    git config --global git-up.bundler.check true

To set it within a project, run this command inside that
project's directory:

    git config git-up.bundler.check true

Replace 'true' with 'false' to disable checking.
EOS
    end

    config("bundler.check") == 'true' || ENV['GIT_UP_BUNDLER_CHECK'] == 'true'
  end

  def prune?
    required_version = "1.6.6"
    config_value = config("fetch.prune")

    if git_version_at_least?(required_version)
      config_value != 'false'
    else
      if config_value == 'true'
        puts "Warning: fetch.prune is set to 'true' but your git version doesn't seem to support it (#{git_version} < #{required_version}). Defaulting to 'false'.".yellow
      end

      false
    end
  end

  def change_count
    @change_count ||= begin
      diff_status   = repo.status
      actual_status = repo.git.status(:porcelain => true).split("\n").map {|l| l[3..-1]}
    
      added         = diff_status.added.select { |(x,y)| actual_status.include? x }
      changed       = diff_status.changed.select { |(x,y)| actual_status.include? x }
      deleted       = diff_status.deleted.select { |(x,y)| actual_status.include? x }
    
      added.length + changed.length + deleted.length
    end
  end

  def config(key)
    repo.config["git-up.#{key}"]
  end

  def git_version_at_least?(required_version)
    (version_array(git_version) <=> version_array(required_version)) >= 0
  end

  def version_array(version_string)
    version_string.split('.').map { |s| s.to_i }
  end

  def git_version
    `git --version`[/\d+(\.\d+)+/]
  end
end


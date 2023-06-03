class MP4Tags

  attr_accessor :current

  TagFlags = {
    album: 'A',         # album title
    title: 's',         # track title
    artist: 'a',        # artist name
    album_artist: 'R',  # album artist name
    composer: 'w',      # composer
    grouping: 'G',      # grouping
    disc: 'd',          # disc number
    discs: 'D',         # total discs
    track: 't',         # track number
    tracks: 'T',        # total tracks
    year: 'y',          # release year
  }

  include SetParams

  def self.load(file)
    new.tap { |t| t.load(file) }
  end

  def self.extract_image(mp4_file:, image_file:)
    begin
      run_command('mp4art',
        '--extract',
        '--art-index', 0,
        '--overwrite',
        '--quiet',
        mp4_file)
    rescue RunCommandFailed => _
      # ignore
    end
    ### FIXME
    # cover is in FILE.art[0].TYPE
    art_paths = dir.glob('*.art*.*').reject { |f| f.extname.downcase == '.gif' }
    raise Error, 'multiple covers found' if art_paths.length > 1
    art_path = art_paths.first
    raise Error, 'no cover to extract' unless art_path
    file = (art_path.dirname / 'extracted-cover').add_extension(art_path.extname)
    file.unlink if file.exist?
    art_path.rename(file)
    file
  end

  def self.update_image(mp4_file:, image_file:)
    # --replace apparently doesn't work, so must do --remove, then --add
    begin
      run_command('mp4art',
        '--quiet',
        '--remove',
        mp4_file)
    rescue RunCommandFailed => _
      # ignore
    end
    run_command('mp4art',
      '--quiet',
      '--add',
      image_file,
      mp4_file)
  end

  def initialize(params={})
    @current = {}
    @changes = {}
    set(params)
  end

  def [](key)
    @changes.has_key?(key) ? @changes[key] : @current[key]
  end

  def []=(key, value)
    raise unless TagFlags[key]
    @changes[key] = value unless @current[key] == value
  end

  def tag_changed?(key)
    @changes.has_key?(key) && @changes[key] != @current[key]
  end

  def changes
    (@current.keys + @changes.keys).map do |key|
      if tag_changed?(key)
        [key, [@current[key], @changes[key]]]
      end
    end.compact.to_h
  end

  def changed?
    !@changes.empty?
  end

  def update(hash)
    hash.each { |k, v| self[k] = v }
  end

  def load(file)
    cmd = [
      'ffprobe',
      '-loglevel', 'error',
      '-show_entries', 'format',
      '-i', file,
    ].map(&:to_s)
    IO.popen(cmd, 'r') do |pipe|
      pipe.readlines.map(&:strip).each do |line|
        if line =~ /^TAG:(.*?)=(.*?)$/
          key, value = $1.to_sym, $2.strip
          info = case key
          when :date
            { year: value.to_i }
          when :track
            track, tracks = value.split('/').map(&:to_i)
            {
              track: track,
              tracks: tracks,
            }
          when :disc
            disc, discs = value.split('/').map(&:to_i)
            {
              disc: disc,
              discs: discs,
            }
          else
            if TagFlags[key]
              { key => value }
            else
              {}
            end
          end
          @current.update(info)
        end
      end
    end
    @current[:track] ||= file.basename.to_s.to_i
  end

  def save(file, force: false)
    return unless changed? || force
    set_flags = {}
    remove_flags = []
    @current.merge(@changes).each do |key, value|
      flag = TagFlags[key] or raise
      if value
        set_flags[flag] = value
      else
        remove_flags << flag
      end
    end
    run_command('mp4tags',
      set_flags.map { |c, v| ["-#{c}", v] },
      !remove_flags.empty? ? ['-remove', remove_flags.join] : nil,
      file)
    run_command('mdimport',
      '-i',
      file)
  end

end
#! /usr/bin/env ruby
# -*- coding: utf-8 -*-

# MP3タグ一括編集アプリ
# id3tagライブラリを使用して複数のMP3ファイルのアーティスト名とアルバム名を一度に書き換えます

require 'optparse'

# MP3タグ編集ライブラリの読み込み（id3tagのみ使用）

def debug_puts(message)
  # 環境変数またはverboseフラグのどちらかが有効な場合に出力
  should_output = ENV['MP3_TAG_EDITOR_DEBUG'] == 'true'
  # optionsが定義されている場合、verboseフラグもチェック
  if defined?(options) && options.is_a?(Hash) && options[:verbose]
    should_output = true
  end
  puts message if should_output
end

begin
  require 'id3tag'
  unless defined?(ID3Tag)
    raise LoadError, "ID3Tag module is not defined after requiring id3tag"
  end
  debug_puts "id3tagを使用します（ID3v2対応）。"
rescue LoadError => e
  puts "エラー: id3tagライブラリがインストールされていません。"
  puts ""
  puts "以下を実行してインストールしてください:"
  puts "   gem install id3tag"
  exit 1
end

# バージョン情報
VERSION = "0.8.0"

# オプション解析
options = {
  targets: [],
  artist: nil,
  album: nil,
  recursive: false,
  dry_run: false,
  verbose: false,
  show_only: false,
  force_id3v1: false,
  force_id3v2: false,
  parse_file_name: false
}

parser = OptionParser.new do |opts|
  opts.banner = "使用方法: #{$0} [オプション] [ファイル...]"
  opts.separator ""
  opts.separator "オプション:"
  
  opts.on("-d", "--directory DIR", "MP3ファイルが含まれるディレクトリまたはMP3ファイルを指定") do |dir|
    options[:targets] << dir
  end
  
  opts.on("-a", "--artist NAME", "アーティスト名を指定") do |name|
    options[:artist] = name
  end
  
  opts.on("-l", "--album NAME", "アルバム名を指定") do |name|
    options[:album] = name
  end
  
  opts.on("-r", "--recursive", "サブディレクトリも再帰的に検索") do
    options[:recursive] = true
  end
  
  opts.on("-n", "--dry-run", "実際には変更せず、変更内容を表示するだけ") do
    options[:dry_run] = true
  end
  
  opts.on("-v", "--verbose", "詳細な情報を表示") do
    options[:verbose] = true
  end
  
  opts.on("-s", "--show", "メタデータを表示するだけ（編集しない）") do
    options[:show_only] = true
  end
  
  opts.on("--force-id3v1", "ID3v1タグを強制的に更新/作成する") do
    options[:force_id3v1] = true
  end
  
  opts.on("--force-id3v2", "ID3v2タグを強制的に更新/作成する") do
    options[:force_id3v2] = true
  end
  
  opts.on("--parse-file-name", "ファイル名からトラック番号とタイトルを抽出して更新する") do
    options[:parse_file_name] = true
  end
  
  opts.on("-h", "--help", "このヘルプを表示") do
    puts opts
    exit
  end
  
  opts.on("--version", "バージョン情報を表示") do
    puts "MP3 Tag Editor #{VERSION}"
    exit
  end
end

begin
  parser.parse!
rescue OptionParser::InvalidOption => e
  puts "エラー: #{e.message}"
  puts parser
  exit 1
end

# 残りの引数をターゲットとして扱う
options[:targets].concat(ARGV)
ARGV.clear

# MP3ファイルを検索する関数
def find_mp3_files(directory, recursive = false)
  pattern = recursive ? "**/*.mp3" : "*.mp3"
  Dir.glob(File.join(directory, pattern)).select { |f| File.file?(f) }
end

# MP3ファイルのタグを読み取る関数
def read_mp3_tags(file_path, full_info: false)
  begin
    File.open(file_path, 'rb') do |file|
      tag = ID3Tag.read(file)
      
      # ジャンルを取得（ID3v2のTCONフレームを優先）
      genre = nil
      id3v2_frames = ID3v2Editor.read(file_path)
      if id3v2_frames && id3v2_frames['TCON']
        # ID3v2のTCONフレームから取得
        genre_text = id3v2_frames['TCON']
        # TCONフレームは "(XX)Genre Name" の形式の場合がある（ID3v1互換）
        # "(XX)" の部分を削除
        genre = genre_text.gsub(/^\(\d+\)/, '').strip
        genre = nil if genre.empty?
      end
      
      # ID3v2から取得できなかった場合、id3tagライブラリから取得を試みる
      if genre.nil? || genre.empty?
        genre = tag.genre
        genre = nil if genre.nil? || genre.empty?
      end
      
      # ID3v1タグからも取得を試みる
      if (genre.nil? || genre.empty?) && tag.respond_to?(:v1_tag) && tag.v1_tag
        v1_genre = tag.v1_tag.genre
        genre = v1_genre if v1_genre && !v1_genre.empty?
      end
      
      # yearを取得（ID3v2のTDRCまたはTYERフレームを優先）
      year = nil
      if id3v2_frames
        # TDRC（ID3v2.4.0）を優先、なければTYER（ID3v2.3.0）を使用
        year = id3v2_frames['TDRC'] || id3v2_frames['TYER']
        # NULL終端を削除
        year = year.strip if year
        year = nil if year && year.empty?
      end
      
      # ID3v2から取得できなかった場合、id3tagライブラリから取得を試みる
      if year.nil? || year.empty?
        year = tag.year
        year = nil if year.nil? || (year.respond_to?(:empty?) && year.empty?)
      end
      
      result = {
        artist: tag.artist,
        album: tag.album,
        title: tag.title,
        year: year,
        track_nr: tag.track_nr,
        genre: genre
      }

      if full_info
        result[:comments] = safe_comments(tag)
        result[:tag_version] = detect_tag_version(tag)
      end

      result
    end
  rescue => e
    { artist: nil, album: nil, title: nil, year: nil, track_nr: nil, genre: nil, error: e.message }
  end
end

# MP3タグ読み取り時の補助関数
def safe_comments(tag)
  return nil unless tag.respond_to?(:comments)
  tag.comments
rescue
  nil
end

def detect_tag_version(tag)
  if tag.respond_to?(:v2_frames) && tag.v2_frames.any?
    "ID3v2"
  elsif tag.respond_to?(:v1_frames) && tag.v1_frames.any?
    "ID3v1"
  else
    "なし"
  end
end

def first_comment(comments)
  return nil if comments.nil?
  comments.is_a?(Array) ? comments.compact.first : comments
end

# ID3v2タグが存在するか確認する関数
def has_id3v2_tag(file_path)
  File.open(file_path, 'rb') do |f|
    header = f.read(10)
    return false if header.nil? || header.length < 10
    return header[0, 3] == 'ID3'
  end
rescue
  false
end

module ID3v2Editor
  HEADER_SIZE = 10
  FRAME_HEADER_SIZE = 10
  VERSION = [3, 0].freeze # ID3v2.3.0
  
  class << self
    def read(file_path)
      File.open(file_path, 'rb') do |f|
        header = f.read(HEADER_SIZE)
        return nil unless header && header.length == HEADER_SIZE
        return nil unless header[0, 3] == 'ID3'
        
        # タグサイズを取得（synchsafe integer）
        tag_size = unsyncsafe_integer(header[6, 4].bytes)
        return nil if tag_size <= 0
        
        # フレームデータを読み取る
        frame_data = f.read(tag_size)
        return nil unless frame_data && frame_data.length == tag_size
        
        parse_frames(frame_data)
      end
    rescue
      nil
    end
    
    def update(file_path, attrs, fallback = {})
      existing = read(file_path)
      frames = existing || {}
      
      # フォールバック値で既存フレームを更新
      fallback.each do |key, value|
        next unless value
        case key
        when :title
          frames['TIT2'] = value.to_s
        when :artist
          frames['TPE1'] = value.to_s
        when :album
          frames['TALB'] = value.to_s
        when :year
          frames['TDRC'] = value.to_s
        when :track_nr, :track
          frames['TRCK'] = value.to_s
        end
      end
      
      # 新しい値を設定
      frames['TPE1'] = attrs[:artist].to_s if attrs[:artist]
      frames['TALB'] = attrs[:album].to_s if attrs[:album]
      frames['TIT2'] = attrs[:title].to_s if attrs[:title]
      if attrs[:track_nr] || attrs[:track]
        track_value = (attrs[:track_nr] || attrs[:track]).to_s
        frames['TRCK'] = track_value
      end
      
      # Windowsエクスプローラー互換性のため、TPE2（アルバムのアーティスト）も設定
      # TPE1（アーティスト）が設定されている場合、TPE2も同じ値に設定
      if attrs[:artist] && frames['TPE1']
        frames['TPE2'] = frames['TPE1']
      elsif frames['TPE1']
        frames['TPE2'] = frames['TPE1']
      end
      
      write(file_path, frames)
    end
    
    def write(file_path, frames)
      # 生フレームデータを分離（元のハッシュを変更しないようにコピー）
      frames_copy = frames.dup
      raw_frames = frames_copy.delete('__raw_frames__') || {}
      
      # フレームデータを構築
      # Windowsエクスプローラー互換性のため、正しく動作しているファイルと同じ順序で書き込む
      # 順序: TPE1, TIT2, TALB, TYER, TDRC, TRCK, TCON, TPE2, ...
      frame_order = ['TPE1', 'TIT2', 'TALB', 'TYER', 'TDRC', 'TRCK', 'TCON', 'TPE2']
      frame_data = ''.force_encoding('BINARY')
      
      # 順序付けられたテキストフレームを先に書き込む
      frame_order.each do |frame_id|
        if frames_copy[frame_id] && !frames_copy[frame_id].empty?
          frame_data << build_frame(frame_id, frames_copy[frame_id].to_s)
        end
      end
      
      # その他のテキストフレームを書き込む
      frames_copy.each do |frame_id, value|
        next if value.nil? || value.empty?
        next if frame_order.include?(frame_id) # 既に書き込んだフレームはスキップ
        next if frame_id == '__raw_frames__' # 生フレームデータはスキップ
        frame_data << build_frame(frame_id, value.to_s)
      end
      
      # 既存の生フレーム（テキストフレーム以外）を書き込む
      raw_frames.each do |frame_id, frame_info|
        # テキストフレームで更新されたものはスキップ
        next if frames_copy.key?(frame_id)
        
        # フレームID（4バイト）
        frame = frame_id.to_s[0, 4].ljust(4, "\0").force_encoding('BINARY')
        # サイズ（4バイト、通常の整数、big-endian）
        size = [frame_info[:data].length].pack('N')
        # フラグ（2バイト）
        flags = frame_info[:flags] || "\0\0".force_encoding('BINARY')
        # フレーム全体
        frame_data << (frame + size + flags + frame_info[:data])
      end
      
      return false if frame_data.empty?
      
      # タグサイズ（synchsafe integer）
      tag_size_bytes = syncsafe_integer(frame_data.length)
      
      # ヘッダーを構築
      header = 'ID3'.force_encoding('BINARY')
      header << [VERSION[0], VERSION[1]].pack('CC')
      header << [0].pack('C') # フラグ（なし）
      header << tag_size_bytes
      
      # ファイル全体を読み込む
      file_content = File.binread(file_path)
      file_size = file_content.length
      
      # 既存のID3v2タグを確認
      has_existing_tag = file_size >= HEADER_SIZE && file_content[0, 3] == 'ID3'
      existing_tag_size = 0
      
      if has_existing_tag
        existing_tag_size = unsyncsafe_integer(file_content[6, 4].bytes)
        existing_tag_size += HEADER_SIZE
      end
      
      # 新しいファイル内容を構築
      new_content = header + frame_data
      
      # 既存タグの後のデータを追加
      if has_existing_tag
        audio_start = existing_tag_size
        
        # 既存タグのサイズフィールドが破損している場合（ファイルサイズを超える）を検出
        if audio_start >= file_size
          # 破損したサイズフィールドの場合、実際のオーディオデータの開始位置を検索
          actual_audio_start = find_mp3_audio_start(file_content, HEADER_SIZE)
          
          if actual_audio_start.nil?
            # オーディオデータの開始位置が見つからない場合、データ損失を防ぐためエラーを発生
            raise "エラー: #{file_path} のID3v2タグのサイズフィールドが破損しており、オーディオデータの開始位置を特定できません。データ損失を防ぐため、書き込みを中止しました。"
          end
          
          audio_start = actual_audio_start
        end
        
        # オーディオデータを追加
        if audio_start < file_size
          new_content << file_content[audio_start..-1]
        else
          # オーディオデータが存在しない場合もエラー
          raise "エラー: #{file_path} にオーディオデータが見つかりません。データ損失を防ぐため、書き込みを中止しました。"
        end
      else
        # ID3v2タグがない場合、ファイル全体をそのまま追加
        new_content << file_content
      end
      
      # ファイルに書き込む
      File.binwrite(file_path, new_content)
      
      true
    end
    
    private
    
    def build_frame(frame_id, value)
      # フレームID（4バイト）
      frame = frame_id.to_s[0, 4].ljust(4, "\0").force_encoding('BINARY')
      
      # Windowsエクスプローラー互換性のため、ASCII文字のみの場合はISO-8859-1を使用
      # マルチバイト文字が含まれる場合はUTF-16BE with BOMを使用
      value_str = value.to_s
      # エンコーディングをUTF-8に統一（既にUTF-8の場合はそのまま）
      begin
        if value_str.encoding == Encoding::UTF_8
          value_utf8 = value_str
        else
          value_utf8 = value_str.encode('UTF-8', invalid: :replace, undef: :replace)
        end
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
        # エンコーディング変換に失敗した場合は、強制的にUTF-8に変換
        value_utf8 = value_str.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
      end
      is_ascii_only = value_utf8.bytes.all? { |b| b < 128 }
      
      if is_ascii_only
        # ISO-8859-1エンコーディング（Windowsエクスプローラー互換性が高い）
        encoding_byte = [0x00].pack('C').force_encoding('BINARY')
        # ISO-8859-1はASCII互換なので、UTF-8から直接変換可能
        encoded_value = value_utf8.force_encoding('ISO-8859-1').encode('ISO-8859-1', invalid: :replace, undef: :replace).force_encoding('BINARY')
        data = encoded_value
        data << "\0".force_encoding('BINARY') # NULL終端（1バイト）
      else
        # UTF-16BE with BOM（マルチバイト文字対応）
        encoding_byte = [0x01].pack('C').force_encoding('BINARY')
        encoded_value = value_utf8.encode('UTF-16BE', invalid: :replace, undef: :replace).force_encoding('BINARY')
        data = "\xFE\xFF".force_encoding('BINARY') # UTF-16BE BOM
        data << encoded_value
        data << "\0\0".force_encoding('BINARY') # NULL終端（2バイト）
      end
      
      # エンコーディングインジケーター + データ
      frame_data = encoding_byte + data
      
      # サイズ（4バイト、通常の整数、big-endian）
      size = [frame_data.length].pack('N')
      
      # フラグ（2バイト、なし）
      flags = "\0\0".force_encoding('BINARY')
      
      frame + size + flags + frame_data
    end
    
    def parse_frames(frame_data)
      frames = {}
      raw_frames = {} # 生のフレームデータを保持（テキストフレーム以外用）
      pos = 0
      
      while pos < frame_data.length - FRAME_HEADER_SIZE
        frame_id = frame_data[pos, 4]
        break if frame_id[0] == "\0" # パディング開始
        
        size_bytes = frame_data[pos + 4, 4]
        size = size_bytes.unpack('N')[0]
        flags = frame_data[pos + 8, 2]
        data = frame_data[pos + 10, size]
        
        # テキストフレームの処理
        if frame_id[0] == 'T' && data && data.length > 1
          # エンコーディングインジケーターを取得（最初のバイト）
          encoding_byte = data.getbyte(0)
          
          # エンコーディングバイトが欠落している場合（BOMが最初にある場合）を検出
          if encoding_byte == 0xFF || encoding_byte == 0xFE
            # エンコーディングバイトが欠落している - データ全体を処理
            text_data = data
            # BOMをチェック
            if text_data.length >= 2 && text_data[0, 2] == "\xFF\xFE"
              # UTF-16LE BOM
              text = text_data[2..-1].force_encoding('UTF-16LE').encode('UTF-8', invalid: :replace, undef: :replace)
            elsif text_data.length >= 2 && text_data[0, 2] == "\xFE\xFF"
              # UTF-16BE BOM
              text = text_data[2..-1].force_encoding('UTF-16BE').encode('UTF-8', invalid: :replace, undef: :replace)
            else
              # BOMなしの場合はISO-8859-1と仮定
              text = text_data.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
            end
          else
            # エンコーディングバイトが存在する - 通常の処理
            text_data = data[1..-1] # エンコーディングバイトを除く
            
            case encoding_byte
            when 0x00
              # ISO-8859-1
              text = text_data.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
            when 0x01
              # UTF-16 with BOM (UTF-16LE or UTF-16BE)
              if text_data.length >= 2
                bom_bytes = text_data[0, 2].bytes
                if bom_bytes == [0xFF, 0xFE]
                  # UTF-16LE BOM
                  content = text_data[2..-1]
                  # BOMが重複している場合を考慮
                  if content.length >= 2 && content[0, 2].bytes == [0xFF, 0xFE]
                    content = content[2..-1]
                  end
                  text = content.force_encoding('UTF-16LE').encode('UTF-8', invalid: :replace, undef: :replace)
                elsif bom_bytes == [0xFE, 0xFF]
                  # UTF-16BE BOM
                  content = text_data[2..-1]
                  # BOMが重複している場合を考慮
                  if content.length >= 2 && content[0, 2].bytes == [0xFE, 0xFF]
                    content = content[2..-1]
                  end
                  text = content.force_encoding('UTF-16BE').encode('UTF-8', invalid: :replace, undef: :replace)
                else
                  # BOMなしの場合はUTF-16LEと仮定
                  text = text_data.force_encoding('UTF-16LE').encode('UTF-8', invalid: :replace, undef: :replace)
                end
              else
                # データが短すぎる場合はUTF-16LEと仮定
                text = text_data.force_encoding('UTF-16LE').encode('UTF-8', invalid: :replace, undef: :replace)
              end
            when 0x02
              # UTF-16BE without BOM
              text = text_data.force_encoding('UTF-16BE').encode('UTF-8', invalid: :replace, undef: :replace)
            when 0x03
              # UTF-8
              text = text_data.force_encoding('UTF-8')
            else
              # 不明なエンコーディングの場合はISO-8859-1と仮定
              text = text_data.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
            end
          end
          
          # NULL終端を削除
          text = text.gsub(/\0+$/, '')
          frames[frame_id] = text unless text.empty?
        else
          # テキストフレーム以外は生データとして保持
          # フレーム全体（ID + サイズ + フラグ + データ）を保存
          raw_frames[frame_id] = {
            size: size,
            flags: flags,
            data: data
          }
        end
        
        pos += FRAME_HEADER_SIZE + size
      end
      
      # 生フレームデータも返す
      frames['__raw_frames__'] = raw_frames unless raw_frames.empty?
      frames
    end
    
    def syncsafe_integer(value)
      # 28ビットの値を32ビットのsynchsafe integerに変換
      # 各バイトの最上位ビットを0にして、残りの7ビットを使用
      bytes = [
        (value >> 21) & 0x7F,
        (value >> 14) & 0x7F,
        (value >> 7) & 0x7F,
        value & 0x7F
      ]
      bytes.pack('C*')
    end
    
    def unsyncsafe_integer(bytes)
      # synchsafe integerを通常の整数に変換
      result = 0
      4.times do |i|
        result |= (bytes[i] & 0x7F) << (7 * (3 - i))
      end
      result
    end
    
    def find_mp3_audio_start(file_content, search_start)
      # MP3フレーム同期パターンを検索（0xFF 0xE0-0xFF）
      # 検索範囲: search_startからファイルサイズまで（最大1MBまで検索）
      max_search_size = [1024 * 1024, file_content.length - search_start].min
      search_end = search_start + max_search_size
      
      (search_start...search_end - 1).each do |i|
        # MP3フレーム同期パターン: 0xFF 0xE0-0xFF (11ビットが1)
        if file_content.getbyte(i) == 0xFF
          next_byte = file_content.getbyte(i + 1)
          # 上位3ビットが111 (0xE0-0xFF) の場合、MP3フレーム同期の可能性が高い
          if next_byte && (next_byte & 0xE0) == 0xE0
            # より確実にするため、次のバイトも確認（MP3ヘッダーの一部）
            # MP3ヘッダーは4バイト: 0xFF 0xE0-0xFF 0xXX 0xXX
            # 3バイト目は通常0x00-0xFFの範囲
            if i + 2 < file_content.length
              return i
            end
          end
        end
      end
      
      nil
    end
  end
end

module ID3v1Editor
  TAG_SIZE = 128
  HEADER = 'TAG'.freeze
  COMMENT_LENGTH = 30
  FIELD_LENGTHS = {
    title: 30,
    artist: 30,
    album: 30,
    year: 4
  }.freeze
  DEFAULTS = {
    title: '',
    artist: '',
    album: '',
    year: '0000',
    comment: '',
    tracknum: 0,
    genre_id: 255
  }.freeze

  class << self
    def update(file_path, attrs, fallback = {})
      existing = read(file_path)
      data = DEFAULTS.dup
      data.merge!(compact_hash(fallback))
      data.merge!(existing) if existing
      attrs.each do |key, value|
        data[key] = value if value
      end
      write(file_path, data)
    end

    def read(file_path)
      return nil unless File.exist?(file_path)
      return nil if File.size(file_path) < TAG_SIZE

      File.open(file_path, 'rb') do |f|
        f.seek(-TAG_SIZE, IO::SEEK_END)
        return nil unless f.read(3) == HEADER
        body = f.read(TAG_SIZE - 3)
        parse_body(body)
      end
    rescue
      nil
    end

    private

    def parse_body(body)
      body = body.dup.force_encoding('BINARY')
      comment_block = (body[94, COMMENT_LENGTH] || '').ljust(COMMENT_LENGTH, "\0")
      tracknum = 0
      comment_text = comment_block
      if comment_block.getbyte(28) == 0
        tracknum = comment_block.getbyte(29) || 0
        comment_text = comment_block[0, 28]
      end
      genre_id = body.getbyte(124) || 255
      {
        title: decode_field(body[0, FIELD_LENGTHS[:title]]),
        artist: decode_field(body[30, FIELD_LENGTHS[:artist]]),
        album: decode_field(body[60, FIELD_LENGTHS[:album]]),
        year: decode_field(body[90, FIELD_LENGTHS[:year]]),
        comment: decode_field(comment_text),
        tracknum: tracknum,
        genre_id: genre_id
      }
    end

    def write(file_path, data)
      payload = build_payload(data)
      File.open(file_path, 'r+b') do |f|
        size = f.stat.size
        has_tag = false
        if size >= TAG_SIZE
          f.seek(-TAG_SIZE, IO::SEEK_END)
          has_tag = f.read(3) == HEADER
        end
        if has_tag
          f.seek(-3, IO::SEEK_CUR)
        else
          f.seek(0, IO::SEEK_END)
        end
        f.write(payload)
      end
      true
    end

    def build_payload(data)
      body = ''.dup.force_encoding('BINARY')
      body << encode_field(data[:title], FIELD_LENGTHS[:title])
      body << encode_field(data[:artist], FIELD_LENGTHS[:artist])
      body << encode_field(data[:album], FIELD_LENGTHS[:album])
      body << encode_field(format_year(data[:year]), FIELD_LENGTHS[:year])
      comment = encode_field(data[:comment], 28)
      track_byte = [data[:tracknum].to_i.clamp(0, 255)].pack('C')
      genre_byte = [data[:genre_id].to_i.clamp(0, 255)].pack('C')
      body << comment
      body << "\0"
      body << track_byte
      body << genre_byte
      HEADER + body
    end

    def encode_field(value, length)
      value = value.to_s
      value = value.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      value = value.byteslice(0, length) || ''
      value = value.ljust(length, "\0")
      value.force_encoding('BINARY')
    end

    def decode_field(bytes)
      bytes.to_s.force_encoding('BINARY').delete("\0").strip
    end

    def format_year(year)
      str = year.to_s.strip
      str.empty? ? '0000' : str[0, 4]
    end

    def compact_hash(hash)
      return {} unless hash
      hash.each_with_object({}) do |(key, value), memo|
        memo[key] = value if value && value != ''
      end
    end
  end
end

# MP3ファイルのメタデータを表示する関数
def show_mp3_tags(file_path, verbose: false)
  begin
    tags = read_mp3_tags(file_path, full_info: true)
    
    puts "ファイル: #{file_path}"
    puts "  タイトル: #{tags[:title] || '(未設定)'}"
    puts "  アーティスト: #{tags[:artist] || '(未設定)'}"
    puts "  アルバム: #{tags[:album] || '(未設定)'}"
    puts "  年: #{tags[:year] || '(未設定)'}"
    puts "  トラック番号: #{tags[:track_nr] || '(未設定)'}"
    puts "  ジャンル: #{tags[:genre] || '(未設定)'}"
    
    if verbose && tags[:tag_version]
      debug_puts "  タグバージョン: #{tags[:tag_version]}"
    end
    
    if verbose && tags[:comments]
      comments = tags[:comments]
      if comments.is_a?(Array)
        comments.each do |comment|
          debug_puts "  コメント: #{comment}"
        end
      elsif comments
        debug_puts "  コメント: #{comments}"
      end
    end
    
    if tags[:error]
      puts "  エラー: #{tags[:error]}"
      return false
    end
    
    puts ""
    true
  rescue => e
    puts "エラー: #{file_path} の読み取り中にエラーが発生しました: #{e.message}"
    if verbose
      debug_puts e.backtrace.join("\n")
    end
    puts ""
    false
  end
end

# ファイル名からトラック番号とタイトルを抽出する関数
def parse_file_name(file_path)
  filename = File.basename(file_path)
  pattern = /^(\d+)[\s_-](.+)\.mp3$/i
  
  match = filename.match(pattern)
  if match
    track_nr = match[1].to_i
    title = match[2].strip
    # タイトルが空文字列の場合はnilを返す（不正なファイル名として扱う）
    return nil if title.empty?
    
    # エンコーディングをUTF-8に統一
    begin
      if title.encoding != Encoding::UTF_8
        title = title.encode('UTF-8', invalid: :replace, undef: :replace)
      end
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      title = title.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
    end
    # エンコーディング変換後も空文字列でないことを確認
    return nil if title.strip.empty?
    
    { track_nr: track_nr, title: title }
  else
    nil
  end
end

# MP3ファイルのタグを編集する関数
def edit_mp3_tags(file_path, artist: nil, album: nil, title: nil, track_nr: nil, dry_run: false, verbose: false, force_id3v1: false, force_id3v2: false)
  begin
    current_tags = read_mp3_tags(file_path, full_info: true)
    old_artist = current_tags[:artist]
    old_album = current_tags[:album]
    old_title = current_tags[:title]
    old_track_nr = current_tags[:track_nr]
    
    # タグの存在確認
    existing_id3v1 = ID3v1Editor.read(file_path)
    existing_id3v2 = has_id3v2_tag(file_path)
    
    # 更新するタグを決定
    # forceオプションが指定されている場合は強制的に更新
    # そうでない場合は、既存のタグのみ更新（両方存在する場合は両方更新）
    update_id3v1 = force_id3v1 || existing_id3v1
    update_id3v2 = force_id3v2 || existing_id3v2
    
    # どちらも更新しない場合
    unless update_id3v1 || update_id3v2
      # このブロックに入る時点で、force_id3v1 と force_id3v2 が false の場合、
      # 両方の existing_id3v1 と existing_id3v2 が false であることが確定している
      puts "エラー: #{file_path} にはID3v1タグもID3v2タグも存在しません。--force-id3v1 または --force-id3v2 オプションを使用してください。"
      return false
    end

    if dry_run
      puts "[DRY RUN] #{file_path}"
      puts "  現在のアーティスト: #{old_artist || '(未設定)'}"
      puts "  現在のアルバム: #{old_album || '(未設定)'}"
      puts "  現在のタイトル: #{old_title || '(未設定)'}"
      puts "  現在のトラック番号: #{old_track_nr || '(未設定)'}"
      
      if update_id3v1
        if artist
          puts "  → アーティストを '#{artist}' に変更（ID3v1タグ#{force_id3v1 ? '、強制' : ''}）"
        end
        if album
          puts "  → アルバムを '#{album}' に変更（ID3v1タグ#{force_id3v1 ? '、強制' : ''}）"
        end
        if title
          puts "  → タイトルを '#{title}' に変更（ID3v1タグ#{force_id3v1 ? '、強制' : ''}）"
        end
        if track_nr
          puts "  → トラック番号を '#{track_nr}' に変更（ID3v1タグ#{force_id3v1 ? '、強制' : ''}）"
        end
      end
      
      if update_id3v2
        if artist
          puts "  → アーティストを '#{artist}' に変更（ID3v2タグ#{force_id3v2 ? '、強制' : ''}）"
        end
        if album
          puts "  → アルバムを '#{album}' に変更（ID3v2タグ#{force_id3v2 ? '、強制' : ''}）"
        end
        if title
          puts "  → タイトルを '#{title}' に変更（ID3v2タグ#{force_id3v2 ? '、強制' : ''}）"
        end
        if track_nr
          puts "  → トラック番号を '#{track_nr}' に変更（ID3v2タグ#{force_id3v2 ? '、強制' : ''}）"
        end
      end
      
      return true
    end

    if verbose
      debug_puts "処理中: #{file_path}"
      debug_puts "  現在のアーティスト: #{old_artist || '(未設定)'}"
      debug_puts "  現在のアルバム: #{old_album || '(未設定)'}"
      debug_puts "  現在のタイトル: #{old_title || '(未設定)'}"
      debug_puts "  現在のトラック番号: #{old_track_nr || '(未設定)'}"
    end
    
    success = true
    
    # ID3v1タグの更新
    if update_id3v1
      fallback = {}
      # titleとtrack_nrが指定されていない場合のみ、既存の値を使用
      fallback[:title] = current_tags[:title] if current_tags[:title] && !title
      fallback[:year] = current_tags[:year] if current_tags[:year]
      primary_comment = first_comment(current_tags[:comments])
      fallback[:comment] = primary_comment if primary_comment
      track = current_tags[:track_nr]
      fallback[:tracknum] = track.to_i if track && !track_nr
      
      attrs_id3v1 = {}
      attrs_id3v1[:artist] = artist if artist
      attrs_id3v1[:album] = album if album
      attrs_id3v1[:title] = title if title
      attrs_id3v1[:tracknum] = track_nr.to_i if track_nr
      
      begin
        ID3v1Editor.update(file_path, attrs_id3v1, fallback)
        debug_puts "  ID3v1タグを更新しました" if verbose
      rescue => e
        puts "  エラー: ID3v1タグの更新に失敗しました: #{e.message}"
        success = false
      end
    end
    
    # ID3v2タグの更新
    if update_id3v2
      fallback = {}
      # titleとtrack_nrが指定されていない場合のみ、既存の値を使用
      fallback[:title] = current_tags[:title] if current_tags[:title] && !title
      fallback[:year] = current_tags[:year] if current_tags[:year]
      track = current_tags[:track_nr]
      fallback[:track_nr] = track if track && !track_nr
      
      attrs_id3v2 = {}
      attrs_id3v2[:artist] = artist if artist
      attrs_id3v2[:album] = album if album
      attrs_id3v2[:title] = title if title
      attrs_id3v2[:track_nr] = track_nr if track_nr
      
      begin
        ID3v2Editor.update(file_path, attrs_id3v2, fallback)
        debug_puts "  ID3v2タグを更新しました" if verbose
      rescue => e
        puts "  エラー: ID3v2タグの更新に失敗しました: #{e.message}"
        success = false
      end
    end

    if verbose && success
      debug_puts "  更新完了"
    end

    success
  rescue => e
    puts "エラー: #{file_path} の処理中にエラーが発生しました: #{e.message}"
    if verbose
      debug_puts e.backtrace.join("\n")
    end
    false
  end
end

# 対話型モード
def interactive_mode
  puts "=== MP3タグ一括編集アプリ ==="
  puts ""
  
  # ディレクトリの入力
  print "MP3ファイルが含まれるディレクトリを入力してください: "
  input = STDIN.gets
  if input.nil?
    puts "エラー: 入力が読み取れませんでした。"
    exit 1
  end
  directory = input.chomp
  
  unless File.directory?(directory)
    puts "エラー: ディレクトリが見つかりません: #{directory}"
    exit 1
  end
  
  # 再帰的検索の確認
  print "サブディレクトリも検索しますか？ (y/n): "
  input = STDIN.gets
  if input.nil?
    puts "エラー: 入力が読み取れませんでした。"
    exit 1
  end
  recursive = input.chomp.downcase == 'y'
  
  # MP3ファイルを検索
  mp3_files = find_mp3_files(directory, recursive)
  
  if mp3_files.empty?
    puts "エラー: MP3ファイルが見つかりませんでした。"
    exit 1
  end
  
  puts ""
  puts "見つかったMP3ファイル: #{mp3_files.size}個"
  if mp3_files.size <= 10
    mp3_files.each_with_index do |file, i|
      puts "  #{i + 1}. #{file}"
    end
  else
    mp3_files.first(5).each_with_index do |file, i|
      puts "  #{i + 1}. #{file}"
    end
    puts "  ... 他 #{mp3_files.size - 5}個"
  end
  puts ""
  
  # モード選択
  puts ""
  puts "モードを選択してください:"
  puts "  1. メタデータを表示するだけ"
  puts "  2. タグを編集する"
  print "選択 (1/2): "
  input = STDIN.gets
  if input.nil?
    puts "エラー: 入力が読み取れませんでした。"
    exit 1
  end
  mode = input.chomp
  
  if mode == '1'
    # 表示モード
    puts ""
    puts "=== メタデータ表示モード ==="
    puts ""
    
    mp3_files.each do |file|
      show_mp3_tags(file, verbose: true)
    end
    
    puts "=== 表示完了 ==="
    puts "表示したファイル数: #{mp3_files.size}個"
    return
  elsif mode != '2'
    puts "エラー: 無効な選択です。"
    exit 1
  end
  
  # 編集モード
  # アーティスト名の入力
  print "新しいアーティスト名を入力してください（変更しない場合はEnter）: "
  input = STDIN.gets
  if input.nil?
    puts "エラー: 入力が読み取れませんでした。"
    exit 1
  end
  artist = input.chomp
  # エンコーディングをUTF-8に統一
  if artist && !artist.empty?
    begin
      # 既にUTF-8の場合はそのまま、そうでない場合は変換
      if artist.encoding != Encoding::UTF_8
        artist = artist.encode('UTF-8', invalid: :replace, undef: :replace)
      end
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      # エンコーディング変換に失敗した場合は、強制的にUTF-8に変換
      artist = artist.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
    end
  else
    artist = nil
  end
  
  # アルバム名の入力
  print "新しいアルバム名を入力してください（変更しない場合はEnter）: "
  input = STDIN.gets
  if input.nil?
    puts "エラー: 入力が読み取れませんでした。"
    exit 1
  end
  album = input.chomp
  # エンコーディングをUTF-8に統一
  if album && !album.empty?
    begin
      # 既にUTF-8の場合はそのまま、そうでない場合は変換
      if album.encoding != Encoding::UTF_8
        album = album.encode('UTF-8', invalid: :replace, undef: :replace)
      end
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      # エンコーディング変換に失敗した場合は、強制的にUTF-8に変換
      album = album.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
    end
  else
    album = nil
  end
  
  if artist.nil? && album.nil?
    puts "エラー: アーティスト名またはアルバム名のいずれかを指定してください。"
    exit 1
  end
  
  # ドライランモードの確認
  print "ドライランモードで実行しますか？ (y/n): "
  input = STDIN.gets
  if input.nil?
    puts "エラー: 入力が読み取れませんでした。"
    exit 1
  end
  dry_run = input.chomp.downcase == 'y'
  
  # 確認
  puts ""
  puts "=== 変更内容の確認 ==="
  puts "ディレクトリ: #{directory}"
  puts "対象ファイル数: #{mp3_files.size}個"
  puts "アーティスト名: #{artist || '(変更なし)'}"
  puts "アルバム名: #{album || '(変更なし)'}"
  puts "ドライランモード: #{dry_run ? '有効' : '無効'}"
  puts ""
  print "この内容で実行しますか？ (y/n): "
  input = STDIN.gets
  if input.nil?
    puts "エラー: 入力が読み取れませんでした。"
    exit 1
  end
  confirm = input.chomp.downcase
  
  unless confirm == 'y'
    puts "キャンセルしました。"
    exit 0
  end
  
  # 実行
  puts ""
  if dry_run
    puts "=== DRY RUN モード（実際には変更しません）==="
    puts ""
  else
    puts "処理を開始します..."
  end
  success_count = 0
  fail_count = 0
  
  mp3_files.each do |file|
    if edit_mp3_tags(file, artist: artist, album: album, title: nil, track_nr: nil, dry_run: dry_run, verbose: true, force_id3v1: false, force_id3v2: false)
      success_count += 1
    else
      fail_count += 1
    end
  end
  
  puts ""
  puts "=== 処理完了 ==="
  puts "成功: #{success_count}個"
  puts "失敗: #{fail_count}個"
end

# メイン処理
if options[:targets].empty?
  # 対話型モード
  interactive_mode
else
  # コマンドライン引数モード
  mp3_files = []
  all_targets_are_files = true
  
  options[:targets].each do |path|
    if File.file?(path)
      unless path.downcase.end_with?('.mp3')
        puts "エラー: MP3ファイルを指定してください: #{path}"
        exit 1
      end
      mp3_files << path
    elsif File.directory?(path)
      all_targets_are_files = false
      mp3_files.concat(find_mp3_files(path, options[:recursive]))
    else
      puts "エラー: ファイルまたはディレクトリが見つかりません: #{path}"
      exit 1
    end
  end
  
  mp3_files.uniq!
  
  if mp3_files.empty?
    puts "エラー: MP3ファイルが見つかりませんでした。"
    exit 1
  end
  
  auto_show = options[:show_only] || (options[:artist].nil? && options[:album].nil? && !options[:parse_file_name] && all_targets_are_files)
  
  if auto_show
    puts "見つかったMP3ファイル: #{mp3_files.size}個"
    puts ""
    puts "=== メタデータ表示モード ==="
    puts ""
    
    success_count = 0
    fail_count = 0
    
    mp3_files.each do |file|
      if show_mp3_tags(file, verbose: options[:verbose])
        success_count += 1
      else
        fail_count += 1
      end
    end
    
    puts "=== 表示完了 ==="
    puts "成功: #{success_count}個"
    puts "失敗: #{fail_count}個"
    exit 0
  end
  
  # 編集モードの場合
  if options[:artist].nil? && options[:album].nil? && !options[:parse_file_name]
    puts "エラー: アーティスト名またはアルバム名のいずれかを指定するか、--parse-file-nameオプションを使用してください。"
    puts parser
    exit 1
  end
  
  puts "見つかったMP3ファイル: #{mp3_files.size}個"
  
  if options[:dry_run]
    puts ""
    puts "=== DRY RUN モード（実際には変更しません）==="
    puts ""
  end
  
  success_count = 0
  fail_count = 0
  skipped_count = 0
  
  mp3_files.each do |file|
    # ファイル名からトラック番号とタイトルを抽出
    title = nil
    track_nr = nil
    if options[:parse_file_name]
      parsed = parse_file_name(file)
      if parsed
        track_nr = parsed[:track_nr]
        title = parsed[:title]
        if options[:verbose]
          debug_puts "ファイル名から抽出: トラック番号=#{track_nr}, タイトル=#{title}"
        end
      else
        # ファイル名がパターンに一致しない場合は一切変更しない
        if options[:verbose]
          puts "スキップ: #{file} - ファイル名がパターンに一致しません: #{File.basename(file)}"
        elsif options[:dry_run]
          puts "[DRY RUN] スキップ: #{file} - ファイル名がパターンに一致しません"
        end
        skipped_count += 1
        next
      end
    end
    
    if edit_mp3_tags(
      file,
      artist: options[:artist],
      album: options[:album],
      title: title,
      track_nr: track_nr,
      dry_run: options[:dry_run],
      verbose: options[:verbose],
      force_id3v1: options[:force_id3v1],
      force_id3v2: options[:force_id3v2]
    )
      success_count += 1
    else
      fail_count += 1
    end
  end
  
  puts ""
  puts "=== 処理完了 ==="
  puts "成功: #{success_count}個"
  puts "失敗: #{fail_count}個"
  if skipped_count > 0
    puts "スキップ: #{skipped_count}個"
  end
end


require 'json'
require 'time'

require 'mysql2'
require 'sinatra/base'

module Isuketch
  class Web < ::Sinatra::Base
    JSON.load_default_options[:symbolize_names] = true

    set :protection, except: [:json_csrf]

    configure :development do
      require 'sinatra/reloader'
      register Sinatra::Reloader

      logger = Logger.new("/tmp/rack.log")
      use Rack::CommonLogger, logger
    end

    Thread.current[:stmts] ||= {}

    helpers do
      def get_dbh
        # データベースの初期化とか
        # DB再起動時、Rackも再起動必要
        dbh = Thread.current[:db]
        unless dbh && dbh.ping
          dbh = Thread.current[:db] =
            begin
              host = ENV['MYSQL_HOST'] || 'localhost'
              port = ENV['MYSQL_PORT'] || '3306'
              user = ENV['MYSQL_USER'] || 'root'
              pass = ENV['MYSQL_PASS'] || ''
              name = 'isuketch'
              mysql = Mysql2::Client.new(
                username: user,
                password: pass,
                database: name,
                host: host,
                port: port,
                encoding: 'utf8mb4',
                init_command: %|
                  SET TIME_ZONE = 'UTC'
                |
              )
              mysql.query_options.update(symbolize_keys: true)
              mysql
            end
        end
        return dbh
      end

      def select_one(dbh, stmt_key, sql, binds)
        select_all(dbh, stmt_key, sql, binds).first
      end

      def select_all(dbh, stmt_key, sql, binds)
        stmt = prepare(dbh, stmt_key, sql)
        result = stmt.execute(*binds)
        result.to_a
      end

      def get_room(dbh, room_id)
        select_one(dbh, __method__, %|
          SELECT `id`, `name`, `canvas_width`, `canvas_height`, `created_at`
          FROM `rooms`
          WHERE `id` = ?
        |, [room_id])
      end

      def get_rooms(dbh, room_ids)
        select_all(dbh, nil, %|
          SELECT `id`, `name`, `canvas_width`, `canvas_height`, `created_at`
          FROM `rooms`
          WHERE `id` IN (#{ Array.new(room_ids.length, '?').join(', ') })
        |, [*room_ids])
      end

      def get_rooms_with_count(dbh, room_ids)
        select_all(dbh, nil, %|
          SELECT r.id, r.name, r.canvas_width, r.canvas_height, r.created_at ,
            (SELECT COUNT(id) FROM strokes s WHERE r.id = s.room_id) AS `stroke_count`
          FROM `rooms` r
          WHERE `id` IN (#{ Array.new(room_ids.length, '?').join(', ') })
        |, [*room_ids])
      end

      def get_strokes(dbh, room_id, greater_than_id)
        select_all(dbh, __method__, %|
          SELECT `id`, `room_id`, `width`, `red`, `green`, `blue`, `alpha`, `created_at`
          FROM `strokes`
          WHERE `room_id` = ?
            AND `id` > ?
          ORDER BY `id` ASC;
        |, [room_id, greater_than_id])
      end

      def to_room_json(room)
        {
          id: room[:id].to_i,
          name: room[:name],
          canvas_width: room[:canvas_width].to_i,
          canvas_height: room[:canvas_height].to_i,
          created_at: (room[:created_at] ? to_rfc_3339(room[:created_at]) : ''),
          strokes: (room[:strokes] ? room[:strokes].map {|stroke| to_stroke_json(stroke) } : []),
          stroke_count: room[:stroke_count] || 0,
          watcher_count: room[:watcher_count] || 0,
        }
      end

      def to_rfc_3339(dt)
        dt.strftime('%Y-%m-%dT%H:%M:%S.%6N%:z').
          sub(/\+00:00/, 'Z') # RFC3339では+00:00のときはZにするという仕様
      end

      def to_stroke_json(stroke)
        {
          id: stroke[:id].to_i,
          room_id: stroke[:room_id].to_i,
          width: stroke[:width].to_i,
          red: stroke[:red].to_i,
          green: stroke[:green].to_i,
          blue: stroke[:blue].to_i,
          alpha: stroke[:alpha].to_f,
          points: (stroke[:points] ? stroke[:points].map {|point| to_point_json(point) } : []),
          created_at: (stroke[:created_at] ? to_rfc_3339(stroke[:created_at]) : ''),
        }
      end

      def to_point_json(point)
        {
          id: point[:id].to_i,
          stroke_id: point[:stroke_id].to_i,
          x: point[:x].to_f,
          y: point[:y].to_f,
        }
      end

      def check_token(dbh, csrf_token)
        select_one(dbh, __method__, %|
          SELECT `id`, `csrf_token`, `created_at` FROM `tokens`
          WHERE `csrf_token` = ?
            AND `created_at` > CURRENT_TIMESTAMP(6) - INTERVAL 1 DAY
        |, [csrf_token])
      end

      def get_stroke_points(dbh, stroke_id)
        select_all(dbh, __method__, %|
          SELECT `id`, `stroke_id`, `x`, `y`
          FROM `points`
          WHERE `stroke_id` = ?
          ORDER BY `id` ASC
        |, [stroke_id])
      end

      def get_watcher_count(dbh, room_id)
        select_one(dbh, __method__, %|
          SELECT COUNT(*) AS `watcher_count`
          FROM `room_watchers`
          WHERE `room_id` = ?
            AND `updated_at` > CURRENT_TIMESTAMP(6) - INTERVAL 3 SECOND
        |, [room_id])[:watcher_count].to_i
      end

      def update_room_watcher(dbh, room_id, csrf_token)
        stmt = prepare(dbh, __method__, %|
          INSERT INTO `room_watchers` (`room_id`, `token_id`)
          VALUES (?, ?)
          ON DUPLICATE KEY UPDATE `updated_at` = CURRENT_TIMESTAMP(6)
        |)
        stmt.execute(room_id, csrf_token)
      end

      def prepare(dbh, stmt_key, sql)
        stmt_key ? (Thread.current[:stmts][stmt_key] ||= dbh.prepare(sql)) : dbh.prepare(sql)
      end
    end

    post '/api/csrf_token' do
      dbh = get_dbh
      dbh.query(%|
        INSERT INTO `tokens` (`csrf_token`)
        VALUES
        (SHA2(CONCAT(RAND(), UUID_SHORT()), 256))
      |)

      # id = dbh.last_id
      token = dbh.query(%|
        SELECT `id`, `csrf_token`, `created_at`
        FROM `tokens`
        WHERE `id` = last_insert_id()
      |).to_a.first

      content_type :json
      JSON.generate(
        token: token[:csrf_token],
      )
    end

    # ルーム一覧
    get '/api/rooms' do
      dbh = get_dbh
      results = select_all(dbh, :api_rooms, %|
        SELECT `room_id`, MAX(`id`) AS `max_id`
        FROM `strokes`
        GROUP BY `room_id`
        ORDER BY `max_id` DESC
        LIMIT 100
      |, [])

      rooms = get_rooms_with_count(dbh, results.map{|res| res[:room_id] })

      content_type :json
      JSON.generate(
        rooms: rooms.map {|room| to_room_json(room) },
      )
    end

    # ルームの作成
    post '/api/rooms' do
      dbh = get_dbh
      token = check_token(dbh, request.env['HTTP_X_CSRF_TOKEN'])
      unless token
        halt(400, {'Content-Type' => 'application/json'}, JSON.generate(
          error: 'トークンエラー。ページを再読み込みしてください。'
        ))
      end

      posted_room = JSON.load(request.body)
      if (posted_room[:name] || '').empty? || !posted_room[:canvas_width] || !posted_room[:canvas_height]
        halt(400, {'Content-Type' => 'application/json'}, JSON.generate(
          error: 'リクエストが正しくありません。'
        ))
      end

      room_id = nil
      begin
        dbh.query(%|BEGIN|)

        stmt = prepare(dbh, :insert_room, %|
          INSERT INTO `rooms`
          (`name`, `canvas_width`, `canvas_height`)
          VALUES
          (?, ?, ?)
        |)
        stmt.execute(posted_room[:name], posted_room[:canvas_width], posted_room[:canvas_height])
        room_id = dbh.last_id

        stmt = prepare(dbh, :insert_room_owner, %|
          INSERT INTO `room_owners`
          (`room_id`, `token_id`)
          VALUES
          (?, ?)
        |)
        stmt.execute(room_id, token[:id])
      rescue
        dbh.query(%|ROLLBACK|)
        halt(500, {'Content-Type' => 'application/json'}, JSON.generate(
          error: 'エラーが発生しました。'
        ))
      else
        dbh.query(%|COMMIT|)
      end

      room = get_room(dbh, room_id)
      content_type :json
      JSON.generate(
        room: to_room_json(room)
      )
    end

    # 入った時にその部屋の線の情報を返す？
    # Reactの方でかなり呼び出している形跡あり。/img/:idの生成に使われている模様。
    get '/api/rooms/:id' do |id|
      dbh = get_dbh()
      room = get_room(dbh, id)
      unless room
        halt(404, {'Content-Type' => 'application/json'}, JSON.generate(
          error: 'この部屋は存在しません。'
        ))
      end

      strokes = get_strokes(dbh, room[:id], 0)
      strokes.each do |stroke|
        stroke[:points] = get_stroke_points(dbh, stroke[:id])
      end
      room[:strokes] = strokes
      room[:watcher_count] = get_watcher_count(dbh, room[:id])

      content_type :json
      JSON.generate(
        room: to_room_json(room)
      )

    end

    # 線の送信
    post '/api/strokes/rooms/:id' do |id|
      dbh = get_dbh()
      token = check_token(dbh, request.env['HTTP_X_CSRF_TOKEN'])
      unless token
        halt(400, {'Content-Type' => 'application/json'}, JSON.generate(
          error: 'トークンエラー。ページを再読み込みしてください。'
        ))
      end

      room = get_room(dbh, id)
      unless room
        halt(404, {'Content-Type' => 'application/json'}, JSON.generate(
          error: 'この部屋は存在しません。'
        ))
      end

      posted_stroke = JSON.load(request.body)
      if !posted_stroke[:width] || !posted_stroke[:points]
        halt(400, {'Content-Type' => 'application/json'}, JSON.generate(
          error: 'リクエストが正しくありません。'
        ))
      end

      # .countネックになりそう？
      stroke_count = get_strokes(dbh, room[:id], 0).count
      if stroke_count == 0
        count = select_one(dbh, %|
          SELECT COUNT(*) as cnt FROM `room_owners`
          WHERE `room_id` = ?
            AND `token_id` = ?
        |, [room[:id], token[:id]])[:cnt].to_i
        if count == 0
          halt(400, {'Content-Type' => 'application/json'}, JSON.generate(
            error: '他人の作成した部屋に1画目を描くことはできません'
          ))
        end
      end

      stroke = nil
      points = []
      begin
        dbh.query(%| BEGIN |)

        stmt = prepare(dbh, :insert_stroke, %|
          INSERT INTO `strokes`
          (`room_id`, `width`, `red`, `green`, `blue`, `alpha`)
          VALUES
          (?, ?, ?, ?, ?, ?)
        |)
        stmt.execute(room[:id], posted_stroke[:width], posted_stroke[:red], posted_stroke[:green], posted_stroke[:blue], posted_stroke[:alpha])
        stroke_id = dbh.last_id
        stroke = { id: stroke_id }.merge(posted_stroke)

        posted_stroke[:points].each do |point|
          stmt = prepare(dbh, :insert_point, %|
            INSERT INTO `points`
            (`stroke_id`, `x`, `y`)
            VALUES
            (?, ?, ?)
          |)
          stmt.execute(stroke_id, point[:x], point[:y])
          point_id = dbh.last_id
          points << { id: point_id }.merge(point)
        end
      rescue
        dbh.query(%| ROLLBACK |)
        halt(500, {'Content-Type' => 'application/json'}, JSON.generate(
          error: 'エラーが発生しました。'
        ))
      else
        dbh.query(%| COMMIT |)
      end

      stroke[:points] = points

      content_type :json
      JSON.generate(
        stroke: to_stroke_json(stroke)
      )
    end

    get '/api/stream/rooms/:id', provides: 'text/event-stream' do |id|
      stream do |writer|
        dbh = get_dbh
        token = check_token(dbh, request.params['HTTP_X_CSRF_TOKEN'])
        token = check_token(dbh, request.params['csrf_token'])
        unless token
          logger.warn("---> mismatched token")
          writer << ("event:bad_request\n" + "data:トークンエラー。ページを再読み込みしてください。\n\n")
          writer.close
          next
        end

        room = get_room(dbh, id)
        unless room
          writer << ("event:bad_request\n" + "data:この部屋は存在しません\n\n")
          writer.close
          next
        end

        update_room_watcher(dbh, room[:id], token[:id])
        watcher_count = get_watcher_count(dbh, room[:id])

        writer << ("retry:500\n\n" + "event:watcher_count\n" + "data:#{watcher_count}\n\n")

        last_stroke_id = 0
        if request.env['HTTP_LAST_EVENT_ID']
          last_stroke_id = request.env['HTTP_LAST_EVENT_ID'].to_i
        end

        5.downto(0) do |i|
          sleep 0.5

          strokes = get_strokes(dbh, room[:id], last_stroke_id)
          strokes.each do |stroke|
            stroke[:points] = get_stroke_points(dbh, stroke[:id])
            writer << ("id:#{stroke[:id]}\n\n" + "event:stroke\n" + "data:#{JSON.generate(to_stroke_json(stroke))}\n\n")
            last_stroke_id = stroke[:id]
          end

          update_room_watcher(dbh, room[:id], token[:id])
          new_watcher_count = get_watcher_count(dbh, room[:id])
          if new_watcher_count != watcher_count
            watcher_count = new_watcher_count
            writer << ("event:watcher_count\n" + "data:#{watcher_count}\n\n")
          end
        end

        writer.close
      end
    end

    if ENV['SQLLOG'] == '1'
      after do
        get_dbh.general_log.writefile(req: request, backtrace: true)
      end
    end
  end
end

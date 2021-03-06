module Blazer
  class QueriesController < ApplicationController
    # skip all filters
    skip_filter *_process_action_callbacks.map(&:filter)

    protect_from_forgery with: :exception

    if ENV["BLAZER_PASSWORD"]
      http_basic_authenticate_with name: ENV["BLAZER_USERNAME"], password: ENV["BLAZER_PASSWORD"]
    end

    layout "blazer/application"

    before_action :ensure_database_url
    before_action :set_query, only: [:show, :edit, :update, :destroy]

    def index
      @queries = Blazer::Query.order(:name)
      @queries = @queries.includes(:creator) if Blazer.user_class
      @trending_queries = Blazer::Audit.group(:query_id).where("created_at > ?", 2.days.ago).having("COUNT(DISTINCT user_id) >= 3").uniq.count(:user_id)
    end

    def new
      @query = Blazer::Query.new(statement: params[:statement])
    end

    def create
      @query = Blazer::Query.new(query_params)
      @query.creator = blazer_user

      if @query.save
        redirect_to query_path(@query, variable_params)
      else
        render :new
      end
    end

    def show
      @statement = @query.statement.dup
      process_vars(@statement)

      @smart_vars = {}
      @sql_errors = []
      @bind_vars.each do |var|
        query = smart_variables[var]
        if query
          rows, error = run_statement(query)
          @smart_vars[var] = rows.map { |v| v.values.reverse }
          @sql_errors << error if error
        end
      end
    end

    def edit
    end

    def run
      @statement = params[:statement]
      process_vars(@statement)

      if @success
        @query = Query.find_by(id: params[:query_id]) if params[:query_id]

        # audit
        if Blazer.audit
          audit = Blazer::Audit.new(statement: @statement)
          audit.query = @query
          audit.user = blazer_user
          audit.save!
        end

        @rows, @error = run_statement(@statement)

        @columns = {}
        if @rows.any?
          @rows.first.each do |key, value|
            @columns[key] =
              case value
              when Integer
                "int"
              when Float
                "float"
              else
                "string-ins"
              end
          end
        end

        @filename = @query.name.parameterize if @query

        @min_width_types = (@rows.first || {}).select { |k, v| v.is_a?(Time) || v.is_a?(String) || smart_columns[k] }.keys

        @boom = {}
        @columns.keys.each do |key|
          query = smart_columns[key]
          if query
            values = @rows.map { |r| r[key] }.compact.uniq
            rows, error = run_statement(ActiveRecord::Base.send(:sanitize_sql_array, [query.sub("{value}", "(?)"), values]))
            @boom[key] = Hash[rows.map(&:values)]
          end
        end

        @linked_columns = linked_columns
      end

      respond_to do |format|
        format.html do
          render layout: false
        end
        format.csv do
          send_data csv_data(@rows), type: "text/csv; charset=utf-8; header=present", disposition: "attachment; filename=\"#{@query ? @query.name.parameterize : 'query'}.csv\""
        end
      end
    end

    def update
      if @query.update(query_params)
        redirect_to query_path(@query, variable_params)
      else
        render :edit
      end
    end

    def destroy
      @query.destroy
      redirect_to root_url
    end

    private

    def ensure_database_url
      render text: "BLAZER_DATABASE_URL required" if !ENV["BLAZER_DATABASE_URL"] && !Rails.env.development?
    end

    def set_query
      @query = Blazer::Query.find(params[:id].to_s.split("-").first)
    end

    def query_params
      params.require(:query).permit(:name, :description, :statement)
    end

    def csv_data(rows)
      CSV.generate do |csv|
        if rows.any?
          csv << rows.first.keys
        end
        rows.each do |row|
          csv << row.values
        end
      end
    end

    def run_statement(statement)
      rows = []
      error = nil
      begin
        Blazer::Connection.transaction do
          Blazer::Connection.connection.execute("SET statement_timeout = #{Blazer.timeout * 1000}") if Blazer.timeout && postgresql?
          result = Blazer::Connection.connection.select_all(statement)
          result.each do |untyped_row|
            row = {}
            untyped_row.each do |k, v|
              row[k] = result.column_types.empty? ? v : result.column_types[k].send(:type_cast, v)
            end
            rows << row
          end
          raise ActiveRecord::Rollback
        end
      rescue ActiveRecord::StatementInvalid => e
        error = e.message.sub(/.+ERROR: /, "")
      end
      [rows, error]
    end

    def extract_vars(statement)
      statement.scan(/\{.*?\}/).map { |v| v[1...-1] }.uniq
    end
    helper_method :extract_vars

    def process_vars(statement)
      @bind_vars = extract_vars(statement)
      @success = @bind_vars.all? { |v| params[v] }

      if @success
        @bind_vars.each do |var|
          value = params[var].presence
          value = value.to_i if value.to_i.to_s == value
          if var.end_with?("_at")
            value = Blazer.time_zone.parse(value) rescue nil
          end
          statement.gsub!("{#{var}}", ActiveRecord::Base.connection.quote(value))
        end
      end
    end

    def variable_params
      params.except(:controller, :action, :id, :host, :query, :table_names, :authenticity_token, :utf8, :_method, :commit, :statement)
    end
    helper_method :variable_params

    def settings
      YAML.load(File.read(Rails.root.join("config", "blazer.yml")))
    end

    def linked_columns
      settings["linked_columns"] || {}
    end

    def smart_columns
      settings["smart_columns"] || {}
    end

    def smart_variables
      settings["smart_variables"] || {}
    end

    def tables
      default_schema = postgresql? ? "public" : Blazer::Connection.connection_config[:database]
      schema = Blazer::Connection.connection_config[:schema] || default_schema
      rows, error = run_statement(Blazer::Connection.send(:sanitize_sql_array, ["SELECT table_name, column_name, ordinal_position, data_type FROM information_schema.columns WHERE table_schema = ?", schema]))
      Hash[rows.group_by { |r| r["table_name"] }.map { |t, f| [t, f.sort_by { |f| f["ordinal_position"] }.map { |f| f.slice("column_name", "data_type") }] }.sort_by { |t, _f| t }]
    end
    helper_method :tables

    def postgresql?
      Blazer::Connection.connection.adapter_name == "PostgreSQL"
    end

    def blazer_user
      send(Blazer.current_user_name) if Blazer.current_user_name
    end
    helper_method :blazer_user

  end
end

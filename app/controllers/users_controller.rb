class UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_int_user
  after_action :verify_authorized, except: [:home, :approval_screen, :approvalscreen_user]

  def set_int_user
    if current_user.role == 'admin'
      @int_users_list = ['admin', 'tier1', 'tier2']
    elsif current_user.role == 'tier1'
      @int_users_list = ['customer', 'organization']
    elsif current_user.role == 'tier2'
      @int_users_list = ['admin', 'tier1', 'tier2', 'customer', 'organization']
    else
      @int_users_list = ['buzz off hacker!!']
    end
  end

  def home
    add_credit_card_interest
    if current_user.role == 'admin' or current_user.role == 'tier2' or current_user.role == 'tier1'
      redirect_to users_url and return
    elsif current_user.role == 'customer' or current_user.role == 'organization'
      if current_user.tier2_approval == 0 or current_user.tier2_approval == 'impending' or current_user.externaluserapproval == 0 or current_user.externaluserapproval=='wait'
        redirect_to approvalscreen_user_url(current_user) and return
      else
        redirect_to user_accounts_path(@current_user) and return
      end
    end
  end

  def approvalscreen
    authorize current_user
    if current_user.admin?
      @user = User.where(role: "admin",tier2_approval: 'impending').or(User.where(role:'tier1',tier2_approval: 'impending')).or(User.where(role:"tier2",tier2_approval: 'impending' ))
    elsif current_user.tier2?
      @user = User.where(tier2_approval: 'impending')
      @account = Account.where(tier2_approval: 'impending')
    end
  end

  def approvalscreen_user
    @user = current_user
  end

  def index
    @users = correct_user_list
    authorize User
  end


  def edit
    @user = User.find(params[:id])
    authorize @user
  end

  def destroy
    user = User.find(params[:id])
    authorize user
    user.destroy
    redirect_to users_url, :notice => "User deleted"
  end

  def new
    @user = User.new
    authorize @user
  end

  def create
    @user = User.new(user_params)
    authorize current_user
    respond_to do |format|
      @user = set_default_status
      # @user.tier2_approval = "Y"
      # @user[:externaluserapproval] = "wait"
      if verify_recaptcha(model: @user) && @user.save
      #if @user.save
        format.html {redirect_to users_url, notice: 'Account was successfully created.'}
        format.json {render :show, status: :created, location: @user}
      else
        format.html {render :new}
        format.json {render json: @user.errors, status: :unprocessable_entity}
      end
      # set_status
    end
  end

  def update
    @user = User.find(params[:id])
    authorize @user
    respond_to do |format|
      if verify_recaptcha(model: @user) && @user.update_attributes(user_params)
        # if @user.update_attributes(user_params)
        # updated_user_params = user_params
        do_update_calculations
        format.html {redirect_to user_accounts_path(@current_user), notice: 'User was successfully updated.'}
        format.json {render :show, status: :created, location: @user}
        # redirect_to user_accounts_path(@current_user), notice: 'User was successfully updated.' and return
      else
        # redirect_to user_accounts_path(@current_user), notice: 'User update unsuccessfull' and return
        format.html {redirect_to user_accounts_path(@current_user), notice: 'User update cancel'}
        format.json {render json: @user.errors, status: :unprocessable_entity}
      end
    end
  end

  def log
    @user = current_user
    authorize @user

    lines = params[:lines]
    if Rails.env == "production"
      @logs = `tail -n #{lines} log/production.log`
    else
      @logs = `tail -n #{lines} log/development.log`
    end
  end


  def user_params
    params.require(:user).permit(:role, :email, :password, :password_confirmation, :phone, :first_name, :last_name, :city, :state, :country, :street, :zip, :updated_email, :updated_phone, :status, :ssn, :isEligibleForTier1, :tier2_approval, :externaluserapproval)
  end

  def correct_user_list

    if current_user.role == 'admin'
      @users = User.where(role: ["admin", "tier1", "tier2"])
    elsif current_user.role == 'tier1'
      @users = User.where(role: ["customer", "organization"])
    elsif current_user.role == 'tier2'
      @users = User.where(role: ["admin", "tier1", "tier2", "customer", "organization"])
    end

  end

  def do_update_calculations
    check_user_and_approval_level
    if user_params['status']
      check_status_function
    elsif user_params['updated_email'] or user_params['updated_phone']
      @user.update_attributes(:status => 'pending')
    end
    if user_params['tier2_approval'] == 'deny' or user_params['externaluserapproval'] == 'reject'
      redirect_to destroy_user_session_path
      # sign_out_and_redirect(current_user)
      # redirect_to signout_path and return
    end
  end

  def check_user_and_approval_level
    if current_user.tier1? and (@user.customer? or @user.organization?)
      @user.update_attributes(:externaluserapproval => 'reject')
      if critical_information
        @user.update_attributes(:isEligibleForTier1 => 'no')
      else
        @user.update_attributes(:isEligibleForTier1 => 'yes')
      end
    elsif current_user.customer? or current_user.organization?
      @user.update_attributes(:externaluserapproval => 'accept')
      if critical_information
        @user.update_attributes(:isEligibleForTier1 => 'no')
      else
        @user.update_attributes(:isEligibleForTier1 => 'yes')
      end
    elsif current_user.tier1? and @user.tier1?
      @user.update_attributes(:isEligibleForTier1 => 'no')
    end
  end

  def critical_information
    is_critical = false
    if @user[:updated_email] or @user[:updated_phone]
      is_critical = true
    end
    is_critical
  end

  def set_default_status
    if current_user.tier1?
      @user[:tier2_approval] = "impending"
      @user[:externaluserapproval] = "wait"
    end
    @user
  end

  def set_status
    if current_user.tier1?
      @user.update_attributes(tier2_approval: 'impending')
    end
  end

  def add_credit_card_interest
    if /[0-9][0-9][0-9][0-9]-[0-9][0-9]-10/ === Date.today.to_s
      cc_accounts = Account.where(acctype: 'Credit Card')
      last_fee = cc_accounts[0].trans.where(:credit => 'fee').last if cc_accounts[0].trans.where(:credit => 'fee').last
      if cc_accounts
        if last_fee
          if cc_accounts[0].trans.where(:credit => 'fee').last.created_at.to_s[0..9] != Date.today.to_s
            cc_accounts.each do |account|
              if account[:statement_balance] != 0
                fee_amount = account[:statement_balance].to_int * 0.2
                Tran.create(:amount => fee_amount,
                            :credit => 'fee',
                            :balance => account[:statement_balance].to_int + fee_amount,
                            :user_id => current_acc[:user_id],
                            :account_id => current_acc[:id],
                            :created_at => DateTime,
                            :updated_at => DateTime)
                account.update_attributes(:statement_balance => account[:statement_balance].to_int + fee_amount)
              end
            end
          end
        else
          cc_accounts.each do |account|
            if account[:statement_balance]
              fee_amount = account[:statement_balance].to_int * 0.2
              Tran.create(:amount => fee_amount,
                          :credit => 'fee',
                          :balance => account[:statement_balance].to_int + fee_amount,
                          :user_id => account[:user_id],
                          :account_id => account[:id],
                          :created_at => DateTime,
                          :updated_at => DateTime)
              account.update_attributes(:statement_balance => account[:statement_balance].to_int + fee_amount)
            end
          end
        end
      end
    elsif /[0-9][0-9][0-9][0-9]-[0-9][0-9]-01/ === Date.today.to_s
      cc_accounts = Account.where(acctype: 'Credit Card')
      cc_accounts.each do |account|
        account.update_attributes(:statement_balance => account.trans.last[:balance])
      end
    end
  end

  def check_status_function
    if user_params['status'] == 'approve'
      if @user[:updated_email]
        @user.update_attributes(:email => @user[:updated_email], :updated_email => nil)
        # @user[:updated_email] = nil
      end
      if @user[:updated_phone]
        @user.update_attributes(:phone => @user[:updated_phone], :updated_phone => nil)
        # @user[:phone] = @user[:updated_phone]
      end
    elsif user_params['status'] == 'declined'
      @user.update_attributes(:updated_email => nil, :updated_phone => nil)
      # @user[:updated_phone] = @user[:updated_email] = nil
      user_params['status'] = nil
    end
    user_params
  end

end


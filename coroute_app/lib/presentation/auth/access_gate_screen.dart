import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../core/widgets/devmonks_branding.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/meta_service.dart';
import '../account/change_password_screen.dart';
import '../admin/master_admin_dashboard.dart';
import '../rider/rider_home_screen.dart';
import 'complete_profile_screen.dart';

class AccessGateScreen extends StatefulWidget {
  const AccessGateScreen({super.key});

  @override
  State<AccessGateScreen> createState() => _AccessGateScreenState();
}

class _AccessGateScreenState extends State<AccessGateScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Sign In Controllers
  final _loginIdentifierController = TextEditingController();
  final _loginPasswordController = TextEditingController();

  // Registration Controllers
  final _regNameController = TextEditingController();
  final _regEmailController = TextEditingController();
  final _regPasswordController = TextEditingController();
  final _regConfirmPasswordController = TextEditingController();
  final _regPhoneController = TextEditingController();
  final _regVehicleNoController = TextEditingController();
  final _regEmergencyNameController = TextEditingController();
  final _regEmergencyPhoneController = TextEditingController();

  bool _obscureLoginPassword = true;
  bool _obscureRegPassword = true;
  bool _obscureRegConfirmPassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  bool _isRegPillion = false;
  String _selectedVehicle = 'Motorcycle (Adv)';
  bool _acceptedTerms = false;

  final List<String> _vehicleTypes = [
    'Motorcycle (Adv)',
    'Motorcycle (Cruiser)',
    'Motorcycle (Sport)',
    'Motorcycle (Commuter)',
    'Scooter / Maxi',
    'Support Car / SUV',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // If the server ended the last session (account on hold, blocked or deleted, or the
    // password was changed elsewhere), say why once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final auth = context.read<AuthService>();
        final reason = auth.lastSignOutReason;
        if (reason != null && reason.isNotEmpty) {
          setState(() => _errorMessage = reason);
          auth.clearSignOutReason();
        }
      } on ProviderNotFoundException catch (_) {
        // No account service above this screen (isolated widget tests).
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _loginIdentifierController.dispose();
    _loginPasswordController.dispose();
    _regNameController.dispose();
    _regEmailController.dispose();
    _regPasswordController.dispose();
    _regConfirmPasswordController.dispose();
    _regPhoneController.dispose();
    _regVehicleNoController.dispose();
    _regEmergencyNameController.dispose();
    _regEmergencyPhoneController.dispose();
    super.dispose();
  }

  /// Routes to the right home screen. The role comes from the server (database), never from the app.
  Future<void> _enter(bool isAdmin) async {
    final auth = context.read<AuthService>();
    if (auth.mustChangePassword) {
      // Temporary password issued by an admin: a new one must be set before anything else.
      final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen(forced: true)));
      if (changed != true || !mounted) return;
    }
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => isAdmin ? const MasterAdminDashboard() : const RiderHomeScreen()),
    );
  }

  String get _privacyUrl => context.read<MetaService>().meta?.privacyUrl.isNotEmpty == true ? context.read<MetaService>().meta!.privacyUrl : '${AppConfig.apiBaseUrl}/privacy';
  String get _termsUrl => context.read<MetaService>().meta?.termsUrl.isNotEmpty == true ? context.read<MetaService>().meta!.termsUrl : '${AppConfig.apiBaseUrl}/terms';

  Future<void> _openUrl(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _showForgotPassword() {
    final support = context.read<MetaService>().meta?.supportEmail ?? '';
    showAppSheet<void>(
      context,
      title: 'Forgot your password?',
      builder: (ctx) => SingleChildScrollView(
        child: Text(
          'If you registered with Google, use "Sign In with Google".\n\n'
          'Otherwise e-mail ${support.isNotEmpty ? support : 'the CoRoute team'} from the address you registered with. '
          'An administrator will give you a temporary password, and the app will ask you to set a new one when you sign in.',
          style: AppText.body.copyWith(color: AppTheme.text2),
        ),
      ),
    );
  }

  // --- SIGN IN ACTION ---
  Future<void> _handleSignIn() async {
    final identifier = _loginIdentifierController.text.trim();
    final password = _loginPasswordController.text.trim();

    if (identifier.isEmpty) {
      setState(() => _errorMessage = 'Please enter your email or callsign.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final auth = context.read<AuthService>();

    final res = await auth.loginRiderWithPassword(
      identifier: identifier,
      password: password,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (res['success'] == true) {
      _enter(res['isAdmin'] == true);
    } else {
      setState(() {
        _errorMessage = res['error']?.toString() ?? 'Invalid credentials.';
      });
    }
  }

  // --- REGISTRATION ACTION ---
  Future<void> _handleRegistration() async {
    final name = _regNameController.text.trim();
    final email = _regEmailController.text.trim();
    final password = _regPasswordController.text.trim();
    final confirmPassword = _regConfirmPasswordController.text.trim();
    final phone = _regPhoneController.text.trim();
    final vehicleNo = _regVehicleNoController.text.trim();
    final emergencyName = _regEmergencyNameController.text.trim();
    final emergencyPhone = _regEmergencyPhoneController.text.trim();

    if (name.isEmpty) {
      setState(() => _errorMessage = 'Please enter your callsign or full name.');
      return;
    }
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _errorMessage = 'Please provide a valid email address.');
      return;
    }
    if (password.length < 8) {
      setState(() => _errorMessage = 'Password must be at least 8 characters long.');
      return;
    }
    if (password != confirmPassword) {
      setState(() => _errorMessage = 'Passwords do not match. Please re-enter.');
      return;
    }
    if (phone.length < 7) {
      setState(() => _errorMessage = 'Please provide your mobile phone number for ride coordination.');
      return;
    }
    if (!_isRegPillion && vehicleNo.length < 3) {
      setState(() => _errorMessage = 'Bike registration number is mandatory for riders (or select Pillion Rider).');
      return;
    }
    if (emergencyName.length < 2) {
      setState(() => _errorMessage = 'Enter the name of your emergency contact.');
      return;
    }
    if (emergencyPhone.length < 7) {
      setState(() => _errorMessage = 'Enter the phone number of your emergency contact.');
      return;
    }
    if (!_acceptedTerms) {
      setState(() => _errorMessage = 'Please accept the Terms of Use and Privacy Policy to register.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final auth = context.read<AuthService>();

    final res = await auth.registerRider(
      name: name,
      email: email,
      password: password,
      phone: phone,
      vehicleType: _isRegPillion ? 'Pillion Rider' : _selectedVehicle,
      vehicleNo: _isRegPillion ? 'PILLION' : vehicleNo,
      emergencyContact: emergencyPhone,
      emergencyContactName: emergencyName,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (res['success'] == true) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Welcome to CoRoute, $name. Your account is ready.'),
          backgroundColor: AppTheme.brand,
        ),
      );
      _enter(res['isAdmin'] == true);
    } else {
      setState(() {
        _errorMessage = res['error']?.toString() ?? 'Registration failed.';
      });
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final auth = context.read<AuthService>();

    final res = await auth.signInWithGoogle();

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (res['success'] == true) {
      final isAdmin = res['isAdmin'] == true;
      if (!auth.isProfileComplete && !isAdmin) {
        final completed = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => const CompleteProfileScreen(forced: true, isGoogleUser: true),
          ),
        );
        if (completed != true || !mounted) return;
      }
      _enter(isAdmin);
    } else {
      setState(() {
        _errorMessage = res['error']?.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 10),
                  const CoRouteHeaderLogo(scale: 0.9),
                  const SizedBox(height: 20),

                  // Tab Selector: SIGN IN vs REGISTER ACCOUNT
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppTheme.soft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: TabBar(
                      controller: _tabController,
                      dividerColor: Colors.transparent,
                      indicatorSize: TabBarIndicatorSize.tab,
                      indicator: BoxDecoration(
                        color: AppTheme.card,
                        borderRadius: BorderRadius.circular(11),
                        boxShadow: dsFloatingShadow(),
                      ),
                      labelColor: AppTheme.text,
                      unselectedLabelColor: AppTheme.muted,
                      labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                      tabs: const [
                        Tab(height: 44, icon: Icon(Icons.login_rounded, size: 18), iconMargin: EdgeInsets.only(bottom: 2), text: 'Sign In'),
                        Tab(height: 44, icon: Icon(Icons.person_add_alt_1_rounded, size: 18), iconMargin: EdgeInsets.only(bottom: 2), text: 'Register Account'),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Error Display Banner
                  if (_errorMessage != null) ...[
                    RideAlert(tier: AlertTier.important, title: _errorMessage!),
                    const SizedBox(height: 16),
                  ],

                  // Card with the active form
                  DsCard(
                    radius: Radii.xl,
                    padding: const EdgeInsets.all(20),
                    child: AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) {
                        return _tabController.index == 0 ? _buildSignInForm() : _buildRegistrationForm();
                      },
                    ),
                  ),

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Small uppercase label above a field (canvas overline).
  Widget _fieldLabel(String text, {Color? color}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: AppText.overline.copyWith(color: color)),
      );

  InputDecoration _dec({required String hint, IconData? icon, Widget? suffix, Color? iconColor}) => InputDecoration(
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon, color: iconColor ?? AppTheme.accentText, size: 20),
        suffixIcon: suffix,
      );

  Widget _eye(bool obscure, VoidCallback onTap) => IconButton(
        tooltip: obscure ? 'Show password' : 'Hide password',
        icon: Icon(obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: AppTheme.muted, size: 20),
        onPressed: onTap,
      );

  Widget _or() => Row(
        children: [
          Expanded(child: Divider(color: AppTheme.border, thickness: 2)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text('OR', style: AppText.overline),
          ),
          Expanded(child: Divider(color: AppTheme.border, thickness: 2)),
        ],
      );

  Widget _googleButton(String label) => Column(
        children: [
          DsButton(
            label: label,
            icon: Icons.g_mobiledata_rounded,
            tone: DsButtonTone.outline,
            fontSize: 15,
            onPressed: _isLoading ? null : _handleGoogleSignIn,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'By continuing with Google you accept the Terms of Use and Privacy Policy.',
              textAlign: TextAlign.center,
              style: AppText.caption,
            ),
          ),
        ],
      );

  // --- SIGN IN FORM ---
  Widget _buildSignInForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Welcome back', style: AppText.title.copyWith(fontSize: 18)),
        const SizedBox(height: 2),
        Text('Sign in to ride with your group.', style: AppText.label),

        const SizedBox(height: 18),

        _fieldLabel('EMAIL OR CALLSIGN'),
        TextField(
          controller: _loginIdentifierController,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxEmailLength)],
          style: AppText.body,
          decoration: _dec(hint: 'e.g. Maverick or rider@example.com', icon: Icons.person_outline_rounded),
        ),

        const SizedBox(height: 14),

        _fieldLabel('PASSWORD'),
        TextField(
          controller: _loginPasswordController,
          obscureText: _obscureLoginPassword,
          style: AppText.body,
          decoration: _dec(
            hint: 'Enter your account password',
            icon: Icons.lock_outline_rounded,
            suffix: _eye(_obscureLoginPassword, () => setState(() => _obscureLoginPassword = !_obscureLoginPassword)),
          ),
        ),

        const SizedBox(height: 20),

        DsButton(
          label: 'SIGN IN',
          icon: _isLoading ? null : Icons.login_rounded,
          onPressed: _isLoading ? null : _handleSignIn,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _showForgotPassword,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('Forgot password?'),
          ),
        ),

        const SizedBox(height: 6),
        _or(),
        const SizedBox(height: 14),
        _googleButton('Sign In with Google'),

        const SizedBox(height: 14),

        Center(
          child: TextButton(
            onPressed: () => _tabController.animateTo(1),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text("Don't have an account? Register as New Rider", textAlign: TextAlign.center),
          ),
        ),
      ],
    );
  }

  // --- REGISTRATION FORM ---
  Widget _buildRegistrationForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.badge_rounded, color: AppTheme.accentText, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Create your account', style: AppText.title.copyWith(fontSize: 18), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text('Your group uses these details to reach you and your family in an emergency.', style: AppText.label),

        const SizedBox(height: 16),

        // 1. Callsign / Full Name
        _fieldLabel('CALLSIGN / FULL NAME *'),
        TextField(
          controller: _regNameController,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxCallsignLength)],
          style: AppText.body,
          decoration: _dec(hint: 'e.g. Phoenix, GhostRider, Santhosh', icon: Icons.person_rounded),
        ),

        const SizedBox(height: 12),

        // 2. Email Address
        _fieldLabel('EMAIL ADDRESS *'),
        TextField(
          controller: _regEmailController,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxEmailLength)],
          keyboardType: TextInputType.emailAddress,
          style: AppText.body,
          decoration: _dec(hint: 'e.g. rider@example.com', icon: Icons.email_rounded),
        ),

        const SizedBox(height: 12),

        // 3. Mobile Phone Number
        _fieldLabel('MOBILE PHONE NUMBER *'),
        TextField(
          controller: _regPhoneController,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxPhoneInputLength)],
          keyboardType: TextInputType.phone,
          style: AppText.body,
          decoration: _dec(hint: 'e.g. +91 98765 43210', icon: Icons.phone_android_rounded),
        ),

        const SizedBox(height: 12),

        // 4. Passwords
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel('PASSWORD *'),
                  TextField(
                    controller: _regPasswordController,
                    obscureText: _obscureRegPassword,
                    style: AppText.body,
                    decoration: _dec(
                      hint: 'Min 8 chars',
                      suffix: _eye(_obscureRegPassword, () => setState(() => _obscureRegPassword = !_obscureRegPassword)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel('CONFIRM *'),
                  TextField(
                    controller: _regConfirmPasswordController,
                    obscureText: _obscureRegConfirmPassword,
                    style: AppText.body,
                    decoration: _dec(
                      hint: 'Repeat pass',
                      suffix: _eye(_obscureRegConfirmPassword, () => setState(() => _obscureRegConfirmPassword = !_obscureRegConfirmPassword)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 18),

        // 5. Rider Role & Vehicle Setup
        _fieldLabel('RIDER ROLE & VEHICLE SETUP *'),
        DsSegment<bool>(
          values: const [false, true],
          selected: _isRegPillion,
          label: (pillion) => pillion ? 'Pillion Rider' : 'Bike Rider',
          onChanged: (pillion) => setState(() => _isRegPillion = pillion),
        ),

        const SizedBox(height: 12),

        if (!_isRegPillion)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('VEHICLE TYPE'),
                    InputDecorator(
                      decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedVehicle,
                          dropdownColor: AppTheme.card,
                          isExpanded: true,
                          isDense: true,
                          style: AppText.body.copyWith(fontSize: 13, fontWeight: FontWeight.w700),
                          items: _vehicleTypes.map((v) => DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis))).toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedVehicle = val);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('BIKE / REG NO *'),
                    TextField(
                      controller: _regVehicleNoController,
                      inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxVehicleNoLength)],
                      textCapitalization: TextCapitalization.characters,
                      style: AppText.body.copyWith(letterSpacing: 1.1),
                      decoration: _dec(hint: 'e.g. KA 01 AB 1234'),
                    ),
                  ],
                ),
              ),
            ],
          )
        else
          DsCard(
            warning: true,
            color: AppTheme.warnTint,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline_rounded, color: AppTheme.warnText, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Pillion Rider: You will participate in convoys without requiring a bike registration number.',
                    style: AppText.caption.copyWith(color: AppTheme.warnText, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 18),

        // 6. Emergency ICE Contacts
        _fieldLabel('EMERGENCY CONTACT *', color: AppTheme.sos),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _regEmergencyNameController,
                inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxContactNameLength)],
                style: AppText.body,
                decoration: _dec(hint: 'Contact Name * (e.g. Brother)', icon: Icons.person_pin_rounded, iconColor: AppTheme.sos),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _regEmergencyPhoneController,
                inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxPhoneInputLength)],
                keyboardType: TextInputType.phone,
                style: AppText.body,
                decoration: _dec(hint: 'Emergency Phone *', icon: Icons.phone_in_talk_rounded, iconColor: AppTheme.sos),
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),

        // Legal acceptance (required to create an account)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: _acceptedTerms,
              activeColor: AppTheme.brand,
              onChanged: (v) => setState(() => _acceptedTerms = v ?? false),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('I accept the ', style: AppText.caption),
                    InkWell(
                      onTap: () => _openUrl(_termsUrl),
                      child: Text('Terms of Use', style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w800, decoration: TextDecoration.underline)),
                    ),
                    Text(' and the ', style: AppText.caption),
                    InkWell(
                      onTap: () => _openUrl(_privacyUrl),
                      child: Text('Privacy Policy', style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w800, decoration: TextDecoration.underline)),
                    ),
                    Text('.', style: AppText.caption),
                  ],
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 10),

        DsButton(
          label: 'REGISTER RIDER ACCOUNT',
          icon: _isLoading ? null : Icons.person_add_alt_1_rounded,
          fontSize: 15,
          onPressed: _isLoading ? null : _handleRegistration,
        ),

        const SizedBox(height: 14),
        _or(),
        const SizedBox(height: 14),
        _googleButton('Sign Up with Google'),

        const SizedBox(height: 12),

        Center(
          child: TextButton(
            onPressed: () => _tabController.animateTo(0),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('Already have an account? Sign In'),
          ),
        ),
      ],
    );
  }
}

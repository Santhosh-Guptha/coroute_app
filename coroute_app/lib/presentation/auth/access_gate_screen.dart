import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/devmonks_branding.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/meta_service.dart';
import '../account/change_password_screen.dart';
import '../admin/master_admin_dashboard.dart';
import '../rider/rider_home_screen.dart';

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
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.slateCard,
        title: const Text('Forgot your password?', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          'If you registered with Google, use "Sign In with Google".\n\n'
          'Otherwise e-mail ${support.isNotEmpty ? support : 'the CoRoute team'} from the address you registered with. '
          'An administrator will give you a temporary password, and the app will ask you to set a new one when you sign in.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK', style: TextStyle(color: AppTheme.neonCyan)))],
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
    if (phone.isEmpty) {
      setState(() => _errorMessage = 'Please provide your mobile phone number for ride coordination.');
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
      vehicleType: _selectedVehicle,
      vehicleNo: vehicleNo,
      emergencyContact: emergencyPhone,
      emergencyContactName: emergencyName,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (res['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🎉 Welcome to CoRoute, $name! Account registered.'),
          backgroundColor: AppTheme.emeraldSafe,
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
      _enter(res['isAdmin'] == true);
    } else {
      setState(() {
        _errorMessage = res['error']?.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
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
                decoration: BoxDecoration(
                  color: AppTheme.slateCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.glassBorder),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: AppTheme.neonCyan,
                  labelColor: AppTheme.neonCyan,
                  unselectedLabelColor: AppTheme.textSecondary,
                  labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  tabs: const [
                    Tab(icon: Icon(Icons.login_rounded, size: 18), text: 'Sign In'),
                    Tab(icon: Icon(Icons.person_add_alt_1_rounded, size: 18), text: 'Register Account'),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Error Display Banner
              if (_errorMessage != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.laserRed.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.laserRed.withOpacity(0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded, color: AppTheme.laserRed, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: AppTheme.laserRed, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Card with TabBarView
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: AnimatedBuilder(
                  animation: _tabController,
                  builder: (context, _) {
                    return _tabController.index == 0
                        ? _buildSignInForm()
                        : _buildRegistrationForm();
                  },
                ),
              ),

              const SizedBox(height: 24),
              const DevMonksBadge(),
              const SizedBox(height: 16),
            ],
          ),
            ),
          ),
        ),
      ),
    );
  }

  // --- SIGN IN FORM ---
  Widget _buildSignInForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Rider & Command Access',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Enter credentials to resume your session',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.neonCyan.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.neonCyan.withOpacity(0.5)),
              ),
              child: const Text(
                'ONLINE',
                style: TextStyle(color: AppTheme.neonCyan, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),

        const SizedBox(height: 18),

        const Text(
          'EMAIL OR CALLSIGN',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _loginIdentifierController,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.person_outline, color: AppTheme.neonCyan, size: 20),
            hintText: 'e.g. Maverick or rider@example.com',
            hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            filled: true,
            fillColor: AppTheme.elevatedCard,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.glassBorder)),
          ),
        ),

        const SizedBox(height: 14),

        const Text(
          'PASSWORD',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _loginPasswordController,
          obscureText: _obscureLoginPassword,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.lock_outline, color: AppTheme.neonCyan, size: 20),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureLoginPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                color: AppTheme.textSecondary,
                size: 18,
              ),
              onPressed: () => setState(() => _obscureLoginPassword = !_obscureLoginPassword),
            ),
            hintText: 'Enter your account password',
            hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            filled: true,
            fillColor: AppTheme.elevatedCard,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.glassBorder)),
          ),
        ),

        const SizedBox(height: 20),

        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _handleSignIn,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.neonCyan,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _isLoading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.login_rounded, size: 18),
                      SizedBox(width: 8),
                      Text('SIGN IN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    ],
                  ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _showForgotPassword,
            child: const Text('Forgot password?', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ),
        ),

        const SizedBox(height: 6),

        // Google Sign-In Button
        Row(
          children: [
            const Expanded(child: Divider(color: AppTheme.subtleBorder)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('OR', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            ),
            const Expanded(child: Divider(color: AppTheme.subtleBorder)),
          ],
        ),
        const SizedBox(height: 14),

        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _isLoading ? null : _handleGoogleSignIn,
            icon: const Icon(Icons.g_mobiledata_rounded, color: Colors.white, size: 28),
            label: const Text(
              'Sign In with Google',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTheme.glassBorder),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'By continuing with Google you accept the Terms of Use and Privacy Policy.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
        ),

        const SizedBox(height: 14),

        Center(
          child: TextButton(
            onPressed: () => _tabController.animateTo(1),
            child: const Text(
              "Don't have an account? Register as New Rider",
              style: TextStyle(color: AppTheme.neonCyan, fontSize: 12),
            ),
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
        const Row(
          children: [
            Icon(Icons.badge_outlined, color: AppTheme.hyperAmber, size: 20),
            SizedBox(width: 8),
            Text(
              'Rider Profile Registration',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const Text(
          'Register your telemetry call-sign and emergency contact',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
        ),

        const SizedBox(height: 16),

        // 1. Callsign / Full Name
        const Text(
          'CALLSIGN / FULL NAME *',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _regNameController,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.person, color: AppTheme.neonCyan, size: 18),
            hintText: 'e.g. Phoenix, GhostRider, Santhosh',
            hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            filled: true,
            fillColor: AppTheme.elevatedCard,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),

        const SizedBox(height: 10),

        // 2. Email Address
        const Text(
          'EMAIL ADDRESS *',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _regEmailController,
          keyboardType: TextInputType.emailAddress,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.email_outlined, color: AppTheme.neonCyan, size: 18),
            hintText: 'e.g. rider@example.com',
            hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            filled: true,
            fillColor: AppTheme.elevatedCard,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),

        const SizedBox(height: 10),

        // 3. Mobile Phone Number
        const Text(
          'MOBILE PHONE NUMBER *',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _regPhoneController,
          keyboardType: TextInputType.phone,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.phone_android, color: AppTheme.neonCyan, size: 18),
            hintText: 'e.g. +91 98765 43210',
            hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            filled: true,
            fillColor: AppTheme.elevatedCard,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),

        const SizedBox(height: 10),

        // 4. Passwords
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('PASSWORD *', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _regPasswordController,
                    obscureText: _obscureRegPassword,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.lock_outline, color: AppTheme.neonCyan, size: 18),
                      suffixIcon: IconButton(
                        icon: Icon(_obscureRegPassword ? Icons.visibility_off : Icons.visibility, color: AppTheme.textSecondary, size: 16),
                        onPressed: () => setState(() => _obscureRegPassword = !_obscureRegPassword),
                      ),
                      hintText: 'Min 8 chars',
                      hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                      filled: true,
                      fillColor: AppTheme.elevatedCard,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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
                  const Text('CONFIRM *', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _regConfirmPasswordController,
                    obscureText: _obscureRegConfirmPassword,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.lock_reset, color: AppTheme.neonCyan, size: 18),
                      suffixIcon: IconButton(
                        icon: Icon(_obscureRegConfirmPassword ? Icons.visibility_off : Icons.visibility, color: AppTheme.textSecondary, size: 16),
                        onPressed: () => setState(() => _obscureRegConfirmPassword = !_obscureRegConfirmPassword),
                      ),
                      hintText: 'Repeat pass',
                      hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                      filled: true,
                      fillColor: AppTheme.elevatedCard,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),
        const Divider(color: AppTheme.glassBorder),
        const SizedBox(height: 10),

        // 5. Vehicle Setup
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('VEHICLE TYPE', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.elevatedCard,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.glassBorder),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedVehicle,
                        dropdownColor: AppTheme.slateCard,
                        isExpanded: true,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
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
                  const Text('VEHICLE REG NO', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _regVehicleNoController,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'e.g. MH 12 AB 1234',
                      hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                      filled: true,
                      fillColor: AppTheme.elevatedCard,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),
        const Divider(color: AppTheme.glassBorder),
        const SizedBox(height: 10),

        // 6. Emergency ICE Contacts
        const Text(
          'EMERGENCY (ICE) CONTACT (OPTIONAL BUT RECOMMENDED)',
          style: TextStyle(color: AppTheme.hyperAmber, fontSize: 10, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _regEmergencyNameController,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.person_pin, color: AppTheme.hyperAmber, size: 18),
                  hintText: 'Contact Name (e.g. Brother)',
                  hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  filled: true,
                  fillColor: AppTheme.elevatedCard,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _regEmergencyPhoneController,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.phone_in_talk, color: AppTheme.hyperAmber, size: 18),
                  hintText: 'Emergency Phone',
                  hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  filled: true,
                  fillColor: AppTheme.elevatedCard,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
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
              activeColor: AppTheme.emeraldSafe,
              onChanged: (v) => setState(() => _acceptedTerms = v ?? false),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('I accept the ', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                    InkWell(onTap: () => _openUrl(_termsUrl), child: const Text('Terms of Use', style: TextStyle(color: AppTheme.neonCyan, fontSize: 12, decoration: TextDecoration.underline))),
                    const Text(' and the ', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                    InkWell(onTap: () => _openUrl(_privacyUrl), child: const Text('Privacy Policy', style: TextStyle(color: AppTheme.neonCyan, fontSize: 12, decoration: TextDecoration.underline))),
                    const Text('.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 10),

        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _handleRegistration,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.emeraldSafe,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _isLoading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.person_add_alt_1_rounded, size: 18),
                      SizedBox(width: 8),
                      Text('REGISTER RIDER ACCOUNT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ],
                  ),
          ),
        ),

        const SizedBox(height: 14),

        // Google Sign-Up Alternative
        Row(
          children: [
            const Expanded(child: Divider(color: AppTheme.subtleBorder)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('OR', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            ),
            const Expanded(child: Divider(color: AppTheme.subtleBorder)),
          ],
        ),
        const SizedBox(height: 14),

        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _isLoading ? null : _handleGoogleSignIn,
            icon: const Icon(Icons.g_mobiledata_rounded, color: Colors.white, size: 28),
            label: const Text(
              'Sign Up with Google',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTheme.glassBorder),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'By continuing with Google you accept the Terms of Use and Privacy Policy.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
        ),

        const SizedBox(height: 12),

        Center(
          child: TextButton(
            onPressed: () => _tabController.animateTo(0),
            child: const Text(
              'Already have an account? Sign In',
              style: TextStyle(color: AppTheme.neonCyan, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}
